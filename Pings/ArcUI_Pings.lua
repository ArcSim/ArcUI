-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_Pings — ping keys + feed window + ping alerts + pingable Arc icons (12.1)
--
-- FULL PARITY PORT of the standalone Arc Pings addon (same engine, same
-- custom options panel). ArcUI extras: pingable Arc spell icons, the AceConfig
-- "Pings" tab as a thin launcher, dormancy when the standalone is loaded.
--   * CHAT_MSG_PING is the one readable receive channel. In combat/restricted
--     content the payload is SECRET -- SetText still renders it (secret sink),
--     timestamps/lifetime/ordering are ours (arrival time is never secret).
--   * NEVER concatenate the payload (string ops on secrets throw): timestamp,
--     text and sender live on SEPARATE FontStrings; rows own their entry for
--     life (secret text can only be SetText once).
--   * Class colors resolve only when the sender is readable (outside
--     combat); honest fallbacks otherwise. No TTS (combat-first: kept simple).
-- Zero idle CPU. No pcall.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local Pings = {}
ns.Pings = Pings

local HAS_ACTION_PINGS = (C_Ping ~= nil)
    and (Enum and Enum.PingSubjectType and Enum.PingSubjectType.ActionReady ~= nil)

-- Dormant when the standalone Arc Pings addon is present (SetMyKick pattern):
-- the standalone owns the feature; ArcUI's copy steps aside completely.
-- ("ArcPingFeed" was the folder name between the two Arc Pings namings, so it
-- is still checked for anyone who installed during that window.)
local STANDALONE_LOADED = C_AddOns and C_AddOns.IsAddOnLoaded
    and (C_AddOns.IsAddOnLoaded("ArcPingFeed") or C_AddOns.IsAddOnLoaded("ArcPings"))

function Pings.IsAvailable() return HAS_ACTION_PINGS and not STANDALONE_LOADED end

-- ── DB ───────────────────────────────────────────────────────────────────────
local DEFAULTS = {
    enabled       = true,    -- ships ON (Arc's call): visible feature, one toggle off
    locked        = true,
    -- window draggable while the options panel is open, regardless of the
    -- lock (Edit-Mode feel; ships ON by Arc's call -- the panel being open IS
    -- the opt-in, and the toggle below turns it off)
    panelDrag     = true,
    -- FIXED window width (no dynamic widening) -- default sized so the
    -- longest callout ("[Spell Name] will be ready in 0:12!" + sender) fits
    width         = 340,
    -- base height: 0 = automatic (hugs the entries); a value keeps the window
    -- at least this tall (it still grows when more entries need the room)
    height        = 0,
    -- static box: always sized for maxEntries and always on screen -- a fixed
    -- frame pings flow through (chat-frame style), never growing/shrinking
    staticSize    = false,
    windowScale   = 1,    -- scales the WHOLE window (everything in it)
    showTitle     = true, -- the "Arc Pings" watermark while unlocked/options open
    -- per-edge padding around the pieces' bounding box (the box shrink-wraps
    -- the layout; these add breathing room, 0 = flush against the pieces)
    rowPadTop     = 2,
    rowPadBottom  = 2,
    maxEntries    = 8,
    entrySeconds  = 12,
    fontSize      = 12,
    fontOutline   = "OUTLINE",  -- "NONE" | "OUTLINE" | "THICKOUTLINE"
    -- chromeless by default: the window is INVISIBLE except its entries;
    -- background/border are opt-in (the border still shows while unlocked)
    showBackground = false,
    showBorder    = false,
    bgAlpha       = 0.35,
    newestOnTop   = true,
    showTimestamp = false,   -- default look: no timestamp (Arc's call)
    showSender    = true,
    -- COMBAT-FIRST RULE (Arc's hard rule): features that only work OUT of
    -- combat do not ship at all. Removed for that reason: pinged-spell icon,
    -- ping-type filter, class-icon sender style (all need the payload, which
    -- is SECRET in combat).
    -- FREE ROW LAYOUT (Plater-style): each piece anchors LEFT or RIGHT of the
    -- row with fine x/y offsets, arranged by dragging in the options preview.
    -- The ping text always fills the space between the innermost pieces.
    -- default layout = Blizzard's chat baseline: "10:59 [Sender]: [Spell] is
    -- ready!" -- timestamp at the left, sender right of it, text flowing after
    iconPos = "left",  iconX = 0,  iconY = 0,
    timePos = "left",  timeX = 0, timeY = 0,
    senderPos = "right", senderX = 0, senderY = 0,
    -- optional piece-to-piece anchoring: "row" (free placement, default) or
    -- the name of another piece ("icon"/"time"/"sender"/"text"). When
    -- anchored, Pos means which SIDE of the target ("left"/"right" of it),
    -- X is the gap from it and Y rides relative to the target's line.
    iconAnchorTo = "row", timeAnchorTo = "row", senderAnchorTo = "time",
    -- per-piece sizes: 0 = automatic (icon follows the row, texts follow the
    -- global Font Size); any positive number overrides just that piece
    iconSize = 0, timeSize = 0, senderSize = 0, textSize = 0,
    -- the ping text still spans (so long lines truncate), but the side it
    -- reads from is draggable like any other piece: textPos anchors the
    -- glyphs LEFT or RIGHT, textX pushes them in from that edge (same-line
    -- pieces still push further; the far side keeps auto-truncating)
    textPos = "left", textX = 0, textY = 0,
    -- colors ({r,g,b})
    colText   = { 0.949, 0.941, 0.925 },  -- #F2F0EC (Arc's palette)
    colTime   = { 0.75, 0.83, 0.92 },
    colSender = { 0.7, 0.9, 0.7 },
    colBg     = { 0.043, 0.059, 0.102 },
    colBorder = { 0.114, 0.165, 0.247 },
    strata        = "MEDIUM",
    animStyle     = "pulse",  -- entrance: none | fade | pulse | flash | zoom
    animInSecs    = 0.3,      -- entrance duration (scales the sequence)
    animOutStyle  = "fade",   -- expiry: none (snap off) | fade
    animOutSecs   = 0.4,      -- expiry fade duration
    showInWorld        = true,
    showInDungeon      = true,   -- normal / heroic / mythic 0
    showInMythicPlus   = true,
    showInRaid         = true,
    showInBattleground = true,
    showInArena        = true,
    showInScenario     = true,   -- scenarios, delves, follower dungeons

    alertsEnabled = false,
    alertSound    = "None",
    alertThrottle = 2,
    -- PING KEYS (opt-in, house rule: new features default OFF).
    -- pkSpells = array of { id, kind, cmd, btn, key = manual override,
    --   mode = "key" (ping key + its own key) | "always" (pings every press) }.
    -- pkOnlySelected narrows the ping key to the picked list (default: any spell).
    pkEnabled     = true,   -- ships ON (Arc's call): the headline feature
    -- INVERTED on purpose: the ping key works on EVERY bound spell out of the
    -- box (a ping key that does nothing on most spells is just confusing), and
    -- this narrows it to the picked list. The option itself still defaults off.
    pkOnlySelected = false,
    -- "Every time I cast it" spells as a group: on by default. There is NO
    -- checkbox for this -- pkToggleKey is the only control, and the holder owns
    -- the live value (the key can flip it in combat). Saved back on regen.
    pkAutoOn      = true,
    pkToggleKey   = "",
    pkKey         = "",
    pkSpells      = nil,
    pos           = nil,
}

local SOUNDS = { None = 0, Alarm = 567458, Bell = 566558, Warning = 567397 }

-- ArcUI's sound pack (36 sounds) -- usable here whenever ArcUI is installed
-- (files load from ArcUI's folder; no dependency otherwise)
local ARC_SOUND_FILES = {
    ["ArcUI: Bleat"] = "Bleat.ogg", ["ArcUI: Cat Meow"] = "CatMeow2.ogg",
    ["ArcUI: Chicken Alarm"] = "ChickenAlarm.ogg", ["ArcUI: Cow Mooing"] = "CowMooing.ogg",
    ["ArcUI: Goat Bleating"] = "GoatBleating.ogg", ["ArcUI: Kitten Meow"] = "KittenMeow.ogg",
    ["ArcUI: Roaring Lion"] = "RoaringLion.ogg", ["ArcUI: Rooster Chicken"] = "RoosterChickenCalls.ogg",
    ["ArcUI: Sheep Bleat"] = "SheepBleat.ogg", ["ArcUI: Air Horn"] = "AirHorn.ogg",
    ["ArcUI: Bike Horn"] = "BikeHorn.ogg", ["ArcUI: Error Beep"] = "ErrorBeep.ogg",
    ["ArcUI: Ringing Phone"] = "RingingPhone.ogg", ["ArcUI: Robot Blip"] = "RobotBlip.ogg",
    ["ArcUI: Warning Siren"] = "WarningSiren.ogg", ["ArcUI: Acoustic Guitar"] = "AcousticGuitar.ogg",
    ["ArcUI: Brass"] = "Brass.mp3", ["ArcUI: Drums"] = "Drums.ogg",
    ["ArcUI: Glass"] = "Glass.mp3", ["ArcUI: Synth Chord"] = "SynthChord.ogg",
    ["ArcUI: Tada Fanfare"] = "TadaFanfare.ogg", ["ArcUI: Temple Bell"] = "TempleBellHuge.ogg",
    ["ArcUI: Xylophone"] = "Xylophone.ogg", ["ArcUI: Applause"] = "Applause.ogg",
    ["ArcUI: Banana Peel Slip"] = "BananaPeelSlip.ogg", ["ArcUI: Batman Punch"] = "BatmanPunch.ogg",
    ["ArcUI: Blast"] = "Blast.ogg", ["ArcUI: Boxing Arena"] = "BoxingArenaSound.ogg",
    ["ArcUI: Double Whoosh"] = "DoubleWhoosh.ogg", ["ArcUI: Heartbeat"] = "HeartbeatSingle.ogg",
    ["ArcUI: Kaching"] = "Kaching.ogg", ["ArcUI: Ultra Instinct"] = "UltraInstinct.mp3",
    ["ArcUI: Ultra Instinct Theme"] = "UltraInstinctTheme.mp3",
    ["ArcUI: Sharp Punch"] = "SharpPunch.ogg", ["ArcUI: Shotgun"] = "Shotgun.ogg",
    ["ArcUI: Squeaky Toy"] = "SqueakyToyShort.ogg", ["ArcUI: Squish"] = "SquishFart.ogg",
    ["ArcUI: Torch"] = "Torch.ogg", ["ArcUI: Water Drop"] = "WaterDrop.ogg",
    ["ArcUI: Cartoon Voice"] = "CartoonVoiceBaritone.ogg", ["ArcUI: Cartoon Walking"] = "CartoonWalking.ogg",
    ["ArcUI: Oh No"] = "OhNo.ogg",
}

-- resolve a sound NAME to something PlaySoundFile accepts: builtin file IDs,
-- then any LibSharedMedia-registered sound (SharedMedia packs, other addons),
-- then ArcUI's pack by path
local function ResolveSound(name)
    if not name or name == "None" then return nil end
    local builtin = SOUNDS[name]
    if builtin and builtin ~= 0 then return builtin end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local f = lsm and lsm:Fetch("sound", name, true)
    if f then return f end
    local arc = ARC_SOUND_FILES[name]
    if arc then return "Interface\\AddOns\\ArcUI\\Sounds\\" .. arc end
    return nil
end

-- the full pickable list: builtins + ArcUI pack (if installed) + every
-- LSM-registered sound
local function BuildSoundList()
    local seen, list = {}, {}
    local function add(n) if n and not seen[n] then seen[n] = true; list[#list + 1] = n end end
    add("Alarm"); add("Bell"); add("Warning")
    if C_AddOns and C_AddOns.DoesAddOnExist and C_AddOns.DoesAddOnExist("ArcUI") then
        for n in pairs(ARC_SOUND_FILES) do add(n) end
    end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if lsm and lsm.List then
        for _i, n in ipairs(lsm:List("sound") or {}) do
            if n ~= "None" then add(n) end
        end
    end
    table.sort(list)
    table.insert(list, 1, "None")
    return list
end

-- sparse per-character storage inside ArcUI's AceDB (ns.db.char.pings)
local dbFallback = {}
local function DB()
    if not (ns.db and ns.db.char) then return dbFallback end
    local db = ns.db.char.pings
    if not db then db = {}; ns.db.char.pings = db end
    return db
end

-- ── SETTING SCOPE ───────────────────────────────────────────────────────────
-- ONE model for everything: an account-wide base with sparse per-character and
-- per-spec patches on top. There is deliberately no second mechanism -- an
-- earlier "Keys For This Character Only" toggle did the same job for two keys
-- and was deleted, because two ways to express one idea is how an options panel
-- becomes confusing.
-- Everything is scoped (account -> character -> spec) EXCEPT these three, and
-- each is excluded for its own reason:
--   pkSpells    the tracked list is one character's bars; a shared base under
--               it would be permanently useless (a Shaman list means nothing
--               to a Mage), so it is honestly per-character rather than
--               consistent-for-its-own-sake.
--   pkAutoOn    RUNTIME STATE, not a setting. You flip it mid-pull with a key
--               and a snippet writes it back. Routing it through the scope
--               layer would silently capture an override into whichever scope
--               the options panel happened to be left on.
--   pkEditScope which scope you are editing -- inherently local to this
--               character, and storing it in a scope would be circular.
local PK_CHAR_ONLY = { pkSpells = true, pkAutoOn = true, pkEditScope = true }

local function GlobalDB()
    if not (ns.db and ns.db.global) then return nil end
    local g = ns.db.global.pings
    if not g then g = {}; ns.db.global.pings = g end
    return g
end

-- ── OVERRIDE LAYER ──────────────────────────────────────────────────────────
-- Everything else (window, entries, alerts) is ACCOUNT-WIDE with sparse
-- per-character and per-spec patches on top:
--
--   global.pings          = the base values, shared by everyone
--   global.pings._ov[key] = { onlyTheSettingsYouChanged }
--
-- The patches are SPARSE, and that is the whole point. An override is not a
-- copy of the config -- it is the two or three settings you wanted different
-- here, so twelve specs cost twelve tiny tables instead of twelve configs.
-- Anything you never touch keeps following the account value, including later
-- changes to it.
--
-- Resolution runs most-specific-first: this char + this spec, then this char,
-- then the account base, then the shipped default.
local SCOPE_ACCOUNT, SCOPE_CHAR, SCOPE_SPEC = "account", "char", "spec"

local function CharKey()
    local n = UnitName("player") or "?"
    local r = GetRealmName and GetRealmName() or "?"
    return n .. "-" .. r
end

local function SpecKey()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local i = GetSpecialization()
    local id = i and GetSpecializationInfo(i)
    if not id then return nil end
    return CharKey() .. "|" .. id
end

-- Which scope the options panel is currently WRITING to. Per character, so one
-- alt can be mid-edit without changing what anyone else sees.
local function ActiveScope()
    local s = DB().pkEditScope
    if s == SCOPE_CHAR or s == SCOPE_SPEC then return s end
    return SCOPE_ACCOUNT
end

local function ScopeKey(scope)
    if scope == SCOPE_CHAR then return CharKey() end
    if scope == SCOPE_SPEC then return SpecKey() end
    return nil
end

-- create=false is the read path: never spawn empty patch tables just by looking
local function OvTable(scope, create)
    local g = GlobalDB()
    if not g then return nil end
    local k = ScopeKey(scope)
    if not k then return nil end
    if not g._ov then
        if not create then return nil end
        g._ov = {}
    end
    local t = g._ov[k]
    if not t and create then t = {}; g._ov[k] = t end
    return t
end

-- Does `key` carry a patch at this scope right now?
local function HasOverride(key, scope)
    local t = OvTable(scope or ActiveScope(), false)
    return t ~= nil and t[key] ~= nil
end

-- Where Cfg("pos") ACTUALLY resolved from, so Render's edge backfill lands in
-- the same scope the window is reading. It used to write straight to DB().pos,
-- which the scope layer no longer reads -- the edges silently stopped updating
-- and an override could never be restored.
local ApplyAll  -- fwd   -- hoisted: the position helpers below call it
-- true while the options panel is open; the scope picker PREVIEWS while it is
local panelOpen = false

-- ONE resolver for reads, so the value shown, the value saved and the value the
-- window uses can never disagree.
--
-- While the options panel is OPEN the picker also PREVIEWS: you see the layer
-- you are EDITING, not the most specific one. Without this, selecting "All My
-- Characters" left a character override still winning -- so the window kept the
-- character's position and it looked like the account had "moved with it", and
-- any edit you then made wrote that position into the account for real.
--
-- Panel closed = normal runtime resolution, most specific wins.
local function ResolveStore(key)
    local editing = panelOpen and ActiveScope() or nil
    if editing ~= SCOPE_CHAR and editing ~= SCOPE_ACCOUNT then
        local spec = OvTable(SCOPE_SPEC, false)
        if spec and spec[key] ~= nil then return spec end
    end
    if editing ~= SCOPE_ACCOUNT then
        local char = OvTable(SCOPE_CHAR, false)
        if char and char[key] ~= nil then return char end
    end
    local g = GlobalDB()
    if g and g[key] ~= nil then return g end
    local c = DB()
    if c[key] ~= nil then return c end
    return nil
end

-- Where Cfg("pos") resolved from, so Render's edge backfill lands in the very
-- same table the window is reading.
local function PosStore()
    return ResolveStore("pos") or DB()
end

-- Where a scoped (window / entries / alerts) setting is WRITTEN right now.
-- Shared by SetCfg and by the window's own drag-stop, so dragging the feed
-- while editing a character or spec captures the position there instead of
-- silently moving it for the whole account.
local function ScopedStore()
    local scope = ActiveScope()
    if scope ~= SCOPE_ACCOUNT then
        local t = OvTable(scope, true)
        if t then return t end
    end
    return GlobalDB() or DB()
end

local function Cfg(key)
    if PK_CHAR_ONLY[key] then
        local db = DB()
        if db[key] ~= nil then return db[key] end
        return DEFAULTS[key]
    end
    local t = ResolveStore(key)
    if t then return t[key] end
    return DEFAULTS[key]
end

-- Write an absolute position into whichever scope is being edited. Always a
-- FRESH table: sharing one between scopes is how in-place edge backfills leak.
--
-- Callers must NOT follow this with ACNotify(): a slider fires set() for every
-- pixel of travel, and rebuilding the whole options panel each time is what
-- made dragging feel sticky.
local function SetWindowPos(x, y)
    local cur = Cfg("pos")
    local top = Cfg("newestOnTop") ~= false
    local p = { (cur and cur[1]) or 0, (cur and cur[2]) or 0,
                top = cur and cur.top, bottom = cur and cur.bottom }
    if x then p[1] = x end
    if y then
        p[2] = y
        if top then p.top = y else p.bottom = y end
    end
    ScopedStore().pos = p
    ApplyAll()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WINDOW + ROWS (engine identical to ArcUI's module)
-- ═══════════════════════════════════════════════════════════════════════════

local win
local rows = {}
local entries = {}
local entryToken = 0
-- true while the ArcUI options panel is open: the window (border + title)
-- stays visible as a placement aid even when locked

-- the window is movable when unlocked, OR while the options panel is open
-- (unless the user turned panel-drag off)
local function CanDrag()
    return not Cfg("locked") or (panelOpen and Cfg("panelDrag") ~= false)
end

-- REQUIREMENT (Arc-verified in-game): CHAT_MSG_PING stops firing when the
-- Blizzard "Show Pings in Chat" or "Enable Pings" settings are off -- the
-- feed silently receives NOTHING. Both are plain CVars; warn + one-click fix.
-- (Only called on 12.1 clients, where the CVars exist.)
local function BlizzPingSettingsOK()
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    return get("enablePings") == "1" and get("showPingsInChat") == "1"
end
local function FixBlizzPingSettings()
    local set = C_CVar and C_CVar.SetCVar or SetCVar
    set("enablePings", "1")
    set("showPingsInChat", "1")
end
local warnedOnce = false
local function WarnIfBlizzSettingsOff()
    if warnedOnce or BlizzPingSettingsOK() then return end
    warnedOnce = true
    print("|cff33ff99Arc Pings|r: |cffff5555the Blizzard setting \"Show Pings in Chat\" (or \"Enable Pings\") is OFF -- the game sends addons nothing, so the feed stays empty.|r Fix it in the ArcUI Pings panel or Blizzard Options > Gameplay > Ping System.")
end
local ROW_PAD = 2
local SenderDisplay  -- fwd: sender text renderer (defined below)

local function RowHeight() return Cfg("fontSize") + 6 end

-- The row FOOTPRINT: when pieces are dragged above/below the line (their Y
-- offsets), each row must grow so stacked rows don't overlap and the window
-- matches what the layout canvas shows. Symmetric around the row center.
-- Anchored pieces ride relative to their target, so their ABSOLUTE y is the
-- anchor chain's sum (depth-capped in case of a cycle).
local PIECE_Y_KEYS      = { icon = "iconY", time = "timeY", sender = "senderY", text = "textY" }
local PIECE_ANCHOR_KEYS = { icon = "iconAnchorTo", time = "timeAnchorTo", sender = "senderAnchorTo" }
local PIECE_POS_KEYS  = { icon = "iconPos",  time = "timePos",  sender = "senderPos",  text = "textPos" }
local PIECE_SIZE_KEYS = { icon = "iconSize", time = "timeSize", sender = "senderSize", text = "textSize" }

local function PieceHeight(which)
    local v = Cfg(PIECE_SIZE_KEYS[which])
    return ((v and v > 0) and v or Cfg("fontSize")) + 2
end

-- Where a piece ACTUALLY sits, as (center, height) measured from the layout
-- centerline. This has to mirror ApplyRowLayout's placement exactly, because
-- RowExtents shrink-wraps the entry box around it and the window clips its
-- children: any piece the box does not account for gets cut off.
--
-- The old PieceAbsY only summed Y OFFSETS down the anchor chain, which is right
-- for left/right placements but wrong for "Top"/"Bottom": those also lift the
-- piece clear of its anchor target (SetPoint BOTTOM->TOP + a 2px gap), and that
-- lift was invisible to the box math. Result: sender anchored to Ping Text at
-- Top landed correctly in the Layout Designer -- whose sample row pins the
-- centerline to its own middle and never consults RowExtents -- but in the real
-- window the centerline sat too high and the sender was clipped away.
--
-- Heights here run ~1px generous (font size + 2 vs the raw glyph height the
-- placement uses). That errs toward a slightly taller box, never a clipped one.
local function PieceBand(which, depth)
    depth = (depth or 0) + 1
    local h = PieceHeight(which)
    local y = Cfg(PIECE_Y_KEYS[which]) or 0
    if which == "text" or depth > 4 then return y, h end
    local a = Cfg(PIECE_ANCHOR_KEYS[which]) or "row"
    -- row-anchored top/bottom pin to the row's own edges, so they are contained
    -- by construction and need no extra allowance
    if a == "row" or not PIECE_Y_KEYS[a] then return y, h end
    local tc, th = PieceBand(a, depth)
    local pos = Cfg(PIECE_POS_KEYS[which]) or "left"
    if pos == "top" then
        return tc + th / 2 + 2 + y + h / 2, h
    elseif pos == "bottom" then
        return tc - th / 2 - 2 + y - h / 2, h
    end
    return tc + y, h
end


-- ASYMMETRIC shrink-wrap: the entry box hugs the pieces' actual bounding box.
-- RowExtents returns how far the layout reaches ABOVE and BELOW the layout
-- centerline (the line pieces' Y offsets are measured from); the box is
-- extents + the user's per-edge padding. No empty space unless the user adds
-- padding, and a piece can never be outside the box by construction.
local function RowExtents()
    local up, down = 0, 0
    -- (spell icon removed -- combat-first rule)
    local function ext(shown, which)
        if not shown then return end
        local c, h = PieceBand(which)
        if (c + h / 2) > up then up = c + h / 2 end
        if (h / 2 - c) > down then down = h / 2 - c end
    end
    ext(Cfg("showTimestamp"), "time")
    ext(Cfg("showSender"), "sender")
    ext(true, "text")
    return up, down
end

local function RowPads()
    local pt = tonumber(Cfg("rowPadTop")) or 2
    local pb = tonumber(Cfg("rowPadBottom")) or 2
    if pt < 0 then pt = 0 end
    if pb < 0 then pb = 0 end
    return pt, pb
end

local function LayoutRowHeight()
    local up, down = RowExtents()
    local pt, pb = RowPads()
    return math.ceil(up + pt + down + pb)
end

-- UIParent's center expressed in the WINDOW's coordinate space -- with a
-- window scale != 1 the two spaces differ, and mixing them (GetCenter vs
-- SetPoint offsets) makes the window drift on every re-anchor
local function UICenterForWin(w)
    local ux, uy = UIParent:GetCenter()
    local s = (w:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    if not s or s == 0 then s = 1 end
    return ux / s, uy / s
end

local function EnsureWindow()
    if win then return win end
    win = CreateFrame("Frame", "ArcUIPingHistory", UIParent, "BackdropTemplate")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(false)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self)
        if CanDrag() then self:StartMoving() end
    end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local cx, cy = self:GetCenter()
        local ux, uy = UICenterForWin(self)
        if cx and ux then
            -- store the EDGES too: the window is re-anchored by its stable
            -- edge (top or bottom per grow direction), never by a center
            -- captured at some other height -- that center drifts every time
            -- the entry count differs from the moment it was saved
            ScopedStore().pos = { cx - ux, cy - uy,
                top    = (self:GetTop() or cy) - uy,
                bottom = (self:GetBottom() or cy) - uy }
        end
    end)
    -- Arc 2.0 skin: flat navy + 1px hairline (no ornate tooltip border)
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    -- NOTHING renders outside the background box: rows (and any dragged/
    -- offset piece) clip at the window rect
    win:SetClipsChildren(true)
    -- and the border can never be covered by row content: a border-only
    -- overlay ABOVE the rows carries the visible edge (the window's own
    -- edge stays transparent)
    win.edge = CreateFrame("Frame", nil, win, "BackdropTemplate")
    win.edge:SetAllPoints(win)
    win.edge:SetFrameLevel(win:GetFrameLevel() + 40)
    win.edge:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    win.edge:EnableMouse(false)
    -- the title floats OUTSIDE the window, centered above its top edge. It
    -- needs its own UIParent-parented frame: the window clips its children,
    -- so anything inside can neither render above the rect nor avoid sitting
    -- on the entries. Out here it takes no layout space and overlaps nothing.
    win.titleHolder = CreateFrame("Frame", nil, UIParent)
    win.titleHolder:SetSize(140, 16)
    win.titleHolder:SetPoint("BOTTOM", win, "TOP", 0, 2)
    win.titleHolder:Hide()
    win.title = win.titleHolder:CreateFontString(nil, "OVERLAY")
    win.title:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    win.title:SetPoint("CENTER", 0, 0)
    win.title:SetAlpha(0.85)
    win.title:SetText("|cff3fc9f2Arc|r|cff8298b4 Pings|r")
    -- the holder mirrors the window's visibility (gated by the wanted flag)
    win:HookScript("OnShow", function(self) self.titleHolder:SetShown(self._titleWanted and true or false) end)
    win:HookScript("OnHide", function(self) self.titleHolder:Hide() end)
    return win
end

local function EnsureRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, EnsureWindow())
    -- the LAYOUT CENTERLINE: pieces anchor to this invisible line (their Y
    -- offsets are measured from it). ApplyRowLayout positions it inside the
    -- row so the box can hug the pieces ASYMMETRICALLY (top and bottom
    -- padding are independent).
    r.line = CreateFrame("Frame", nil, r)
    r.line:SetHeight(1)
    r.time = r:CreateFontString(nil, "OVERLAY")
    r.time:SetJustifyH("LEFT")
    r.time:SetTextColor(0.6, 0.7, 0.8)
    r.text = r:CreateFontString(nil, "OVERLAY")
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r.sender = r:CreateFontString(nil, "OVERLAY")
    r.sender:SetJustifyH("RIGHT")
    -- fonts MUST be set before the first SetText ("Font not set" error --
    -- AddEntry writes text before Render runs ApplyRowLayout)
    local size = Cfg("fontSize")
    r.time:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    r.text:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    r.sender:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    -- pinged spell/item icon (populated when the payload is readable)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.icon:Hide()
    rows[i] = r
    return r
end

-- (PingIconFromText removed with the spell-icon feature -- combat-first rule)

-- width read that tolerates a fontstring holding SECRET text (its measured
-- width may itself be secret -- fall back to a sane estimate).
-- UNBOUNDED width: GetStringWidth returns the CURRENT (possibly truncated)
-- width, so once a line was squeezed the fit check believed the lie forever.
local function SafeWidth(fs, fallback)
    local w
    if fs.GetUnboundedStringWidth then w = fs:GetUnboundedStringWidth()
    elseif fs.GetStringWidth then w = fs:GetStringWidth() end
    if w == nil or (issecretvalue and issecretvalue(w)) then return fallback end
    return w
end

-- FREE ROW LAYOUT: every piece (icon / timestamp / sender) anchors to the
-- row's LEFT or RIGHT edge with its own fine x/y offsets (arranged by drag in
-- the options preview); the ping text fills whatever remains between the
-- widest extents of each side.
local function ApplyRowLayout(r)
    local size = Cfg("fontSize")
    local outline = Cfg("fontOutline")
    if outline == "NONE" then outline = "" end
    local font = STANDARD_TEXT_FONT
    -- per-piece font sizes (0/nil = the global Font Size)
    local tsz = Cfg("timeSize");   tsz = (tsz and tsz > 0) and tsz or size
    local ssz = Cfg("senderSize"); ssz = (ssz and ssz > 0) and ssz or size
    local xsz = Cfg("textSize");   xsz = (xsz and xsz > 0) and xsz or size
    r.time:SetFont(font, tsz, outline)
    r.text:SetFont(font, xsz, outline)
    r.sender:SetFont(font, ssz, outline)
    -- text color: per-row state color (readable pings) beats the base color
    local ct = Cfg("colText")
    r.text:SetTextColor(ct[1], ct[2], ct[3])
    local cti = Cfg("colTime")
    r.time:SetTextColor(cti[1], cti[2], cti[3])
    -- sender renders LIVE from the stored readable identity, so option changes
    -- hit rows already on screen. Secret senders keep their raw SetText render.
    if r._senderClean then
        r.sender:SetText(SenderDisplay(r._senderClean))
    end
    -- sender colour is the user's custom colour, full stop. Class colour was
    -- REMOVED (combat-first rule): the sender identity is secret in combat and
    -- CHAT_MSG_PING never carries a usable GUID, so it could only ever have
    -- worked out of combat. See the pings memory before reconsidering.
    local cs = Cfg("colSender")
    r.sender:SetTextColor(cs[1], cs[2], cs[3])

    local showTime, showSender = Cfg("showTimestamp"), Cfg("showSender")
    r.time:SetShown(showTime)
    r.sender:SetShown(showSender)
    -- spell icon removed (combat-first rule: the payload is secret in combat,
    -- so the icon could never show there)
    if r.icon then r.icon:Hide() end

    r.time:ClearAllPoints()
    r.sender:ClearAllPoints()
    r.text:ClearAllPoints()

    -- pieces only PUSH the text while they share its line: a piece dragged
    -- above/below the text's band stops affecting the text's span (the
    -- "callout moves when I lift the sender on top" fix)
    local textBandY = Cfg("textY") or 0
    local band = xsz + 4
    local leftExtent, rightExtent = 0, 0

    -- position the LAYOUT CENTERLINE inside the row: the box shrink-wraps the
    -- pieces, so the line sits (top extent + top padding) below the row's top
    -- edge. The canvas sample pins it to its center instead (stable drag
    -- space; the band overlay shows the real box there). Containment is BY
    -- CONSTRUCTION: the box is derived from the pieces, nothing can be
    -- outside it.
    if r.line then
        local upExt, _downExt = RowExtents()
        local padT = RowPads()
        r.line:ClearAllPoints()
        if r._isSample then
            r.line:SetPoint("LEFT", r, "LEFT", 0, 0)
            r.line:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        else
            r.line:SetPoint("LEFT", r, "TOPLEFT", 0, -(upExt + padT))
            r.line:SetPoint("RIGHT", r, "TOPRIGHT", 0, -(upExt + padT))
        end
    end
    local L = r.line or r

    local P = {
        -- icon entry kept ONLY as an anchor-fallback target (never shown)
        icon   = { el = r.icon,   shown = false,      pos = "left", x = 0, y = 0, w = 0, anchor = "row" },
        time   = { el = r.time,   shown = showTime,   pos = Cfg("timePos"),   x = Cfg("timeX") or 0,   y = Cfg("timeY") or 0,   w = SafeWidth(r.time, 44),  anchor = Cfg("timeAnchorTo") or "row" },
        sender = { el = r.sender, shown = showSender, pos = Cfg("senderPos"), x = Cfg("senderX") or 0, y = Cfg("senderY") or 0, w = SafeWidth(r.sender, 60), anchor = Cfg("senderAnchorTo") or "row" },
    }

    -- resolve each piece's EFFECTIVE row side / extent / absolute Y, following
    -- anchor chains (cycles and hidden targets fall back to free row placement)
    local eff = {}
    local function Resolve(key, visited)
        if eff[key] then return eff[key] end
        local pc = P[key]
        visited = visited or {}
        local a = pc.anchor
        if visited[key] then a = "row" end
        visited[key] = true
        -- only left/right placements push the text span; center/top/bottom
        -- pieces float without squeezing the callout
        local sideExtent = (pc.pos == "left" or pc.pos == "right") and (pc.x + pc.w) or nil
        if a == "row" then
            eff[key] = { mode = "row", side = pc.pos, extent = sideExtent, y = pc.y }
        elseif a == "text" then
            eff[key] = { mode = "text", side = Cfg("textPos") or "left", extent = nil, y = (Cfg("textY") or 0) + pc.y }
        elseif P[a] and P[a].shown then
            local te = Resolve(a, visited)
            local grows = (pc.pos == "left" or pc.pos == "right")
                and ((te.side == "right") and (pc.pos == "left") or (te.side ~= "right") and (pc.pos == "right"))
            local extent = te.extent and (grows and (te.extent + 4 + pc.x + pc.w) or te.extent) or nil
            eff[key] = { mode = "piece", target = P[a].el, side = te.side, extent = extent, y = te.y + pc.y }
        elseif P[a] then
            -- anchor target exists but is HIDDEN: the piece's pos means
            -- "left/right OF the target", NOT a row side -- so the orphan
            -- takes over the TARGET'S spot (its side of the row), it does
            -- not fly to the opposite window edge
            local te = Resolve(a, visited)
            local side = te.side or pc.pos
            local ext = (side == "left" or side == "right") and (pc.x + pc.w) or nil
            eff[key] = { mode = "row", side = side, extent = ext, y = pc.y }
        else
            eff[key] = { mode = "row", side = pc.pos, extent = sideExtent, y = pc.y }
        end
        return eff[key]
    end

    local deferred = {}  -- text-anchored pieces place AFTER the text lays out
    for key, pc in pairs(P) do
        if pc.shown then
            local e = Resolve(key)
            local el = pc.el
            if e.mode == "text" then
                deferred[#deferred + 1] = { pc = pc, e = e }
            elseif e.mode == "row" then
                -- e.side may differ from pc.pos (orphaned-anchor fallback
                -- inherits the hidden target's side) -- place by e.side
                local sidePos = e.side or pc.pos
                if sidePos == "right" then
                    el:SetPoint("RIGHT", L, "RIGHT", -pc.x, pc.y)
                elseif sidePos == "center" then
                    el:SetPoint("CENTER", L, "CENTER", pc.x, pc.y)
                elseif sidePos == "top" then
                    el:SetPoint("TOP", r, "TOP", pc.x, math.min(0, pc.y))
                elseif sidePos == "bottom" then
                    el:SetPoint("BOTTOM", r, "BOTTOM", pc.x, math.max(0, pc.y))
                else
                    el:SetPoint("LEFT", L, "LEFT", pc.x, pc.y)
                end
            else
                -- anchored: sit on the chosen SIDE of the target with a small
                -- base gap; X widens the gap, Y rides relative to the target
                local tel = e.target
                if pc.pos == "right" then
                    el:SetPoint("LEFT", tel, "RIGHT", 4 + pc.x, pc.y)
                elseif pc.pos == "center" then
                    el:SetPoint("CENTER", tel, "CENTER", pc.x, pc.y)
                elseif pc.pos == "top" then
                    el:SetPoint("BOTTOM", tel, "TOP", pc.x, 2 + pc.y)
                elseif pc.pos == "bottom" then
                    el:SetPoint("TOP", tel, "BOTTOM", pc.x, -2 + pc.y)
                else
                    el:SetPoint("RIGHT", tel, "LEFT", -(4 + pc.x), pc.y)
                end
            end
            if el.SetJustifyH and el ~= r.icon then
                local j = (e.mode == "row") and (e.side or pc.pos) or pc.pos
                el:SetJustifyH((j == "right") and "RIGHT" or (j == "left") and "LEFT" or "CENTER")
            end
            -- extent push (same-line band check on the piece's ABSOLUTE y)
            if e.extent and math.abs((e.y or 0) - textBandY) < band then
                if e.side == "right" then
                    if e.extent > rightExtent then rightExtent = e.extent end
                else
                    if e.extent > leftExtent then leftExtent = e.extent end
                end
            end
        end
    end

    -- the text's anchored side (textPos) is user-positioned: its own offset
    -- (textX) wins over the piece extents when it is larger; the far side
    -- keeps the auto inset while the line FITS
    local ty = Cfg("textY") or 0
    local li = leftExtent + ((leftExtent > 0) and 5 or 0)
    local ri = rightExtent + ((rightExtent > 0) and 5 or 0)
    local tx = Cfg("textX") or 0
    local tpos = Cfg("textPos")
    local rightSide = tpos == "right"
    local centerText = tpos == "center"
    if rightSide then
        if tx > ri then ri = tx end
        r.text:SetJustifyH("RIGHT")
    elseif centerText then
        r.text:SetJustifyH("CENTER")
    else
        if tx > li then li = tx end
        r.text:SetJustifyH("LEFT")
    end
    -- TOO-LONG LINES stay INSIDE the box: a line wider than the span is
    -- constrained to the span so the fontstring ellipsizes cleanly ("...")
    -- instead of overflowing into the window edge and getting clipped
    -- mid-letter (the "mkeeper] will be ready" bug). The worst-case preview
    -- exists so users size the width to never hit this.
    local needed = SafeWidth(r.text, nil)
    local avail = (r:GetWidth() or 0) - li - ri
    r._neededW = needed and (li + needed + ri) or nil
    if centerText and not (needed and needed > avail) then
        r.text:SetPoint("CENTER", L, "CENTER", tx, ty)
    else
        r.text:SetPoint("LEFT", L, "LEFT", li, ty)
        r.text:SetPoint("RIGHT", L, "RIGHT", -ri, ty)
    end

    -- pieces anchored TO THE TEXT: the fontstring SPANS the row, so its rect
    -- edge is the window edge -- anchoring there dumped pieces at the far
    -- corner (the "X0 isn't the text's right edge" bug). Place against the
    -- measured GLYPH box instead: "Right of it" + X0 = flush against the
    -- last letter. Secret text is unmeasurable: fall back to the span edge.
    if #deferred > 0 then
        local rowW = r:GetWidth() or 0
        local tw = SafeWidth(r.text, nil)
        local gL, gR
        if tw then
            if rightSide then
                gR = rowW - ri; gL = gR - tw
            elseif centerText then
                local mid = rowW / 2 + tx
                gL, gR = mid - tw / 2, mid + tw / 2
            else
                gL = li; gR = gL + tw
            end
        end
        for _di, d in ipairs(deferred) do
            local pc, e = d.pc, d.e
            local el = pc.el
            local ey = e.y or 0
            if not gL then
                -- SECRET PAYLOAD PATH (in combat / restricted content): the ping
                -- text is unmeasurable, so there is no glyph box to anchor to and
                -- we fall back to the fontstring's own rect. That rect SPANS the
                -- row, so every case has to be handled here -- letting top/bottom/
                -- center drop into the left branch anchored them off the row's
                -- left edge, where SetClipsChildren deleted them. That was the
                -- "sender vanishes the moment I enter combat" bug: the layout was
                -- right out of combat and silently different in it.
                if pc.pos == "right" then
                    el:SetPoint("LEFT", r.text, "RIGHT", 4 + pc.x, pc.y)
                elseif pc.pos == "top" then
                    el:SetPoint("BOTTOM", r.text, "TOP", pc.x, 2 + pc.y)
                elseif pc.pos == "bottom" then
                    el:SetPoint("TOP", r.text, "BOTTOM", pc.x, -2 + pc.y)
                elseif pc.pos == "center" then
                    el:SetPoint("CENTER", r.text, "CENTER", pc.x, pc.y)
                else
                    el:SetPoint("RIGHT", r.text, "LEFT", -(4 + pc.x), pc.y)
                end
            elseif pc.pos == "right" then
                el:SetPoint("LEFT", L, "LEFT", gR + 4 + pc.x, ey)
            elseif pc.pos == "center" then
                el:SetPoint("CENTER", L, "LEFT", (gL + gR) / 2 + pc.x, ey)
            elseif pc.pos == "top" then
                el:SetPoint("BOTTOM", L, "LEFT", (gL + gR) / 2 + pc.x, ty + xsz / 2 + 2 + pc.y)
            elseif pc.pos == "bottom" then
                el:SetPoint("TOP", L, "LEFT", (gL + gR) / 2 + pc.x, ty - xsz / 2 - 2 + pc.y)
            else
                el:SetPoint("RIGHT", L, "LEFT", gL - 4 - pc.x, ey)
            end
        end
    end
end

local function Render()
    if not win then return end
    local width = Cfg("width")
    local rowH  = LayoutRowHeight()
    local top   = Cfg("newestOnTop")
    local n     = #entries
    -- size BEFORE layout: ApplyRowLayout measures the row's width for the
    -- never-truncate check, so it must see the current size
    local function LayoutRows(w)
        local maxNeed = w
        for _i, e in ipairs(entries) do
            local r = e.row
            if r then
                r:SetSize(w - 12, rowH)
                ApplyRowLayout(r)
                if r._neededW and r._neededW + 12 > maxNeed then maxNeed = r._neededW + 12 end
            end
        end
        return maxNeed
    end
    -- FULL TEXT ALWAYS (Arc's guarantee): the configured width is the BASE --
    -- the window is never narrower than it -- but if a line on screen needs
    -- more room, the window widens to fit that line and returns to the base
    -- when it expires. A readable callout is never truncated. (Secret lines
    -- are unmeasurable and render at the base width.)
    local need = LayoutRows(width)
    if need > width then
        width = math.ceil(need)
        LayoutRows(width)
    end
    -- GROW-DIRECTION pinning: the window is anchored by CENTER, so height
    -- changes used to stretch it both ways and shift every row. Preserve the
    -- STABLE edge across the resize instead: newest-on-top keeps the TOP edge
    -- fixed (grows downward), newest-on-bottom keeps the BOTTOM edge fixed
    -- (grows upward) -- same fix in both directions.
    local ux, uy = UICenterForWin(win)
    local wcx = win:GetCenter()
    local edgeY = top and win:GetTop() or win:GetBottom()
    -- ApplyAll has just re-anchored (scope switch, typed X/Y). The frame's live
    -- geometry is still LAST frame's at this point, so pinning from it would
    -- yank the window straight back to where it was -- which is exactly why
    -- switching back to an override appeared to do nothing. Trust the STORED
    -- position for this one pass.
    if win._arcPosDirty then
        win._arcPosDirty = nil
        local sp = Cfg("pos")
        if sp and ux and uy then
            wcx = (sp[1] or 0) + ux
            local se = top and sp.top or sp.bottom
            edgeY = se and (se + uy) or edgeY
        end
    end
    -- CONSTANT padding: the title floats outside the window, so
    -- unlocking/locking can never shift the entries
    local padTop = 6
    -- static box: sized for the MAX entry count, so expiring pings never
    -- shrink the window
    local staticBox = Cfg("staticSize")
    local rowsFor = staticBox and (Cfg("maxEntries") or 8) or math.max(1, n)
    local autoH = rowsFor * (rowH + ROW_PAD) + padTop + 6
    local hBase = tonumber(Cfg("height")) or 0
    win:SetSize(width, (hBase > autoH) and hBase or autoH)
    if wcx and edgeY and ux then
        win:ClearAllPoints()
        if top then
            win:SetPoint("TOP", UIParent, "CENTER", wcx - ux, edgeY - uy)
        else
            win:SetPoint("BOTTOM", UIParent, "CENTER", wcx - ux, edgeY - uy)
        end
        -- keep the saved edges current (migrates old center-only positions)
        local pos = PosStore().pos
        if pos then
            local t, b = win:GetTop(), win:GetBottom()
            if t then pos.top = t - uy end
            if b then pos.bottom = b - uy end
        end
    end
    -- a static box is a permanent HUD element: it stays on screen when empty
    win:SetShown(Cfg("enabled") and (n > 0 or not Cfg("locked") or panelOpen or staticBox))
    -- rows hug the window's stable edge so existing entries never move:
    -- newest-on-top stacks down from the top, newest-on-bottom stacks up
    -- from the bottom (entries[1] is always the newest)
    for i, e in ipairs(entries) do
        local r = e.row
        if r then
            r:ClearAllPoints()
            if top then
                r:SetPoint("TOPLEFT", win, "TOPLEFT", 6, -padTop - (i - 1) * (rowH + ROW_PAD))
            else
                r:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 6, 6 + (i - 1) * (rowH + ROW_PAD))
            end
            r:Show()
        end
    end
end

local EnsureRowAnims  -- fwd (animations section below)

local function FinalizeRemove(token)
    for i, e in ipairs(entries) do
        if e.token == token then
            if e.row then
                e.row:Hide()
                e.row:SetAlpha(1)   -- reset for the next claim
                e.row.free = true
            end
            table.remove(entries, i)
            Render()
            return
        end
    end
end

local function RemoveEntry(token)
    for _i, e in ipairs(entries) do
        if e.token == token then
            local r = e.row
            -- CR-style expiry: fade the row out, then actually remove it
            if r and r:IsShown() and Cfg("animOutStyle") == "fade" then
                EnsureRowAnims(r)
                if not r.fadeOutAG:IsPlaying() then
                    r.fadeOutA:SetDuration(math.max(0.05, tonumber(Cfg("animOutSecs")) or 0.4))
                    r._onFadeOutDone = function() FinalizeRemove(token) end
                    r.fadeOutAG:Play()
                end
            else
                FinalizeRemove(token)
            end
            return
        end
    end
end

local function ClaimRow()
    for i = 1, Cfg("maxEntries") do
        local r = EnsureRow(i)
        if r.free or not r.claimed then
            r.free, r.claimed = false, true
            return r
        end
    end
    local oldest = entries[#entries]
    if oldest then
        local r = oldest.row
        table.remove(entries, #entries)
        return r
    end
    return EnsureRow(1)
end

-- ── animations (Cooldown-Reminder-style kit, on OUR row frames = combat-safe) ─
function EnsureRowAnims(r)
    if r.pulseAG then return end
    -- "pulse": quick scale bounce
    r.pulseAG = r:CreateAnimationGroup()
    local up = r.pulseAG:CreateAnimation("Scale")
    up:SetOrder(1); up:SetScale(1.12, 1.12); up:SetDuration(0.12)
    local down = r.pulseAG:CreateAnimation("Scale")
    down:SetOrder(2); down:SetScale(1 / 1.12, 1 / 1.12); down:SetDuration(0.18)
    r.pulseUp, r.pulseDown = up, down
    -- "flash": alpha bounces (urgent)
    r.flashAG = r:CreateAnimationGroup()
    r.flashSteps = {}
    for i = 1, 2 do
        local dim = r.flashAG:CreateAnimation("Alpha")
        dim:SetOrder(i * 2 - 1); dim:SetFromAlpha(1); dim:SetToAlpha(0.25); dim:SetDuration(0.1)
        local bright = r.flashAG:CreateAnimation("Alpha")
        bright:SetOrder(i * 2); bright:SetFromAlpha(0.25); bright:SetToAlpha(1); bright:SetDuration(0.1)
        r.flashSteps[#r.flashSteps + 1] = dim
        r.flashSteps[#r.flashSteps + 1] = bright
    end
    -- "fade": entrance fade-in (alpha 0 -> 1)
    r.fadeInAG = r:CreateAnimationGroup()
    r.fadeInA = r.fadeInAG:CreateAnimation("Alpha")
    r.fadeInA:SetFromAlpha(0); r.fadeInA:SetToAlpha(1)
    r.fadeInA:SetDuration(0.3); r.fadeInA:SetSmoothing("OUT")
    -- "zoom": CR-style pop-in (0.7 -> 1.15 -> 1.0, fading in over the pop)
    r.zoomAG = r:CreateAnimationGroup()
    local z1 = r.zoomAG:CreateAnimation("Scale")
    z1:SetOrder(1); z1:SetScaleFrom(0.7, 0.7); z1:SetScaleTo(1.15, 1.15)
    z1:SetDuration(0.12); z1:SetSmoothing("OUT")
    local z2 = r.zoomAG:CreateAnimation("Scale")
    z2:SetOrder(2); z2:SetScaleFrom(1.15, 1.15); z2:SetScaleTo(1.0, 1.0)
    z2:SetDuration(0.08); z2:SetSmoothing("IN")
    local zi = r.zoomAG:CreateAnimation("Alpha")
    zi:SetOrder(1); zi:SetFromAlpha(0); zi:SetToAlpha(1); zi:SetDuration(0.12)
    r.zoom1, r.zoom2, r.zoomIn = z1, z2, zi
    -- expiry fade-out -> finalize removal via per-row callback
    r.fadeOutAG = r:CreateAnimationGroup()
    r.fadeOutA = r.fadeOutAG:CreateAnimation("Alpha")
    r.fadeOutA:SetFromAlpha(1); r.fadeOutA:SetToAlpha(0)
    r.fadeOutA:SetDuration(0.4); r.fadeOutA:SetSmoothing("OUT")
    r.fadeOutAG:SetScript("OnFinished", function()
        local cb = r._onFadeOutDone
        r._onFadeOutDone = nil
        if cb then cb() end
    end)
end

local function PlayNewPingAnim(r)
    EnsureRowAnims(r)
    -- a new ping on a row that was mid-expiry must snap back to full life
    r.fadeOutAG:Stop(); r._onFadeOutDone = nil; r:SetAlpha(1)
    local style = Cfg("animStyle")
    if style == "none" then return end
    r.pulseAG:Stop(); r.flashAG:Stop(); r.fadeInAG:Stop(); r.zoomAG:Stop()
    -- entrance duration scales the whole sequence (CR pattern)
    local D = math.max(0.05, tonumber(Cfg("animInSecs")) or 0.3)
    if style == "flash" then
        for _i, a in ipairs(r.flashSteps) do a:SetDuration(D / #r.flashSteps) end
        r.flashAG:Play()
    elseif style == "fade" then
        r.fadeInA:SetDuration(D)
        r.fadeInAG:Play()
    elseif style == "zoom" then
        r.zoom1:SetDuration(D * 0.6)
        r.zoomIn:SetDuration(D * 0.6)
        r.zoom2:SetDuration(D * 0.4)
        r.zoomAG:Play()
    else -- pulse
        r.pulseUp:SetDuration(D * 0.4)
        r.pulseDown:SetDuration(D * 0.6)
        r.pulseAG:Play()
    end
end

-- ── alerts ───────────────────────────────────────────────────────────────────
local lastAlertAt = 0
-- (TTS removed entirely -- Arc's call: keep v1 simple; the alert sound is the
-- audio cue)

local function FireAlerts(text)
    if not Cfg("alertsEnabled") then return end
    local now = GetTime()
    if (now - lastAlertAt) < (Cfg("alertThrottle") or 0) then return end
    lastAlertAt = now
    local f = ResolveSound(Cfg("alertSound"))
    if f then PlaySoundFile(f, "Master") end
end

-- ── sender name ──────────────────────────────────────────────────────────────
-- The sender arrives as a PLAYER HYPERLINK ("|Hplayer:Name-Realm|h[Name]|h"),
-- not a plain name -- extract the name before roster compares.
local function CleanSenderName(sender)
    if sender == nil then return nil end
    if issecretvalue and issecretvalue(sender) then return nil end
    if type(sender) ~= "string" then return nil end
    local n = sender:match("|Hplayer:([^:|%]]+)")
    return n or sender
end

-- the sender piece's display string. Name only -- the class-icon style was
-- REMOVED (combat-first rule: the sender is secret in combat, the icon could
-- never show there).
function SenderDisplay(cleanName)
    return cleanName and (Ambiguate and Ambiguate(cleanName, "short") or cleanName) or ""
end

-- ── entries ──────────────────────────────────────────────────────────────────
-- preview entry: shown in the REAL window while the options panel is open and
-- no actual ping is on screen -- so every option is judged against the real
-- thing, not just the canvas
local function RemovePreviewEntries()
    local removed = false
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.preview then
            if e.row then e.row:Hide(); e.row:SetAlpha(1); e.row.free = true end
            table.remove(entries, i)
            removed = true
        end
    end
    return removed
end

-- NOTE: no ping-type filter. In combat the payload is SECRET, so pings can't
-- be classified -- a filter would either break there or silently eat cooldown
-- pings. Combat-first rule: the option doesn't ship at all.
local function AddEntry(text, sender, guid, isPreview)
    if not Cfg("enabled") then return end
    -- a real ping replaces the preview immediately
    if not isPreview then RemovePreviewEntries() end
    EnsureWindow()
    entryToken = entryToken + 1
    local token = entryToken
    local r = ClaimRow()

    r.time:SetText(date("%H:%M:%S"))
    -- readable payloads: optional custom template + state color; secret -> raw.
    -- The GUID path can recover the clean name even when the sender string is
    -- secret (in-combat identity secrecy) -- full sender rendering in combat.
    -- (PingLab: guid arg is NIL on current builds -- kept for when it lands.)
    local cleanName = CleanSenderName(sender)
    -- the payload renders exactly as the game sent it: Custom Format was
    -- REMOVED (combat-first) -- rewriting the line needs to READ it, and it is
    -- secret in combat. SetText is a one-way sink, which is why the line still
    -- displays there at all.
    if text ~= nil then r.text:SetText(text) else r.text:SetText("") end
    -- (pinged-spell icon removed -- combat-first rule: the spellID lives
    -- inside the payload, which is secret in combat; no link extractor exists)
    r.icon:Hide()
    -- store the readable identity; ApplyRowLayout renders sender text + color
    -- from it LIVE (style/color changes hit rows already on screen). Secret
    -- senders render raw via SetText here and keep it.
    r._senderClean = cleanName
    if not cleanName then
        if sender ~= nil then r.sender:SetText(sender) else r.sender:SetText("") end
    end

    table.insert(entries, 1, { token = token, row = r, preview = isPreview or nil })
    while #entries > Cfg("maxEntries") do
        local e = table.remove(entries, #entries)
        if e.row then e.row:Hide(); e.row:SetAlpha(1); e.row.free = true end
    end
    Render()
    PlayNewPingAnim(r)
    if isPreview then return end  -- no alerts, no expiry: lives while the panel is open
    FireAlerts(text)

    local life = Cfg("entrySeconds")
    if life and life > 0 then
        C_Timer.After(life, function() RemoveEntry(token) end)
    end
end

-- ── preview callout ─────────────────────────────────────────────────────────
-- The sample line used by the layout canvas and the "Show Test Ping" button.
-- It used to be a hardcoded Lightning Bolt, which is nonsense on twelve of the
-- thirteen classes, so it is built from a spell the player ACTUALLY has.
--
-- Source is the ACTIVE SPEC's own skill line (SpellBookSkillLineInfo.specID is
-- set, isOffSpec is false), which is where a spec's signature abilities live --
-- the general class line is mostly baseline filler. The LAST non-passive entry
-- is preferred because the spellbook is ordered by level learned, so it is
-- usually a real cooldown rather than a filler button, which suits the
-- "will be ready in 0:12" wording.
--
-- Cached per spec: the scan walks the whole book, and the answer only changes
-- when the spec does.
local previewSpellID, previewSpec

local function PreviewSpellID()
    -- GetSpecialization is only a deprecated alias now (Blizzard_Deprecated-
    -- Specialization aliases it to this); call the real one, keep the old as a
    -- fallback in case that shim ever loads first.
    local csi = C_SpecializationInfo
    local spec = (csi and csi.GetSpecialization and csi.GetSpecialization())
              or (GetSpecialization and GetSpecialization()) or 0
    if previewSpellID and previewSpec == spec then return previewSpellID end
    previewSpec = spec

    local sb = C_SpellBook
    if not (sb and sb.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank) then
        previewSpellID = nil
        return nil
    end
    local BANK = Enum.SpellBookSpellBank.Player
    local specPick, anyPick

    for line = 1, (sb.GetNumSpellBookSkillLines() or 0) do
        local info = sb.GetSpellBookSkillLineInfo(line)
        -- offSpecID set = this whole line belongs to a spec the player is not in
        if info and not info.isGuild and not info.offSpecID then
            local first = (info.itemIndexOffset or 0) + 1
            local last  = (info.itemIndexOffset or 0) + (info.numSpellBookItems or 0)
            for slot = first, last do
                local item = sb.GetSpellBookItemInfo(slot, BANK)
                if item and item.spellID and not item.isPassive and not item.isOffSpec then
                    anyPick = item.spellID
                    -- a line carrying a specID IS the active spec's line
                    if info.specID then specPick = item.spellID end
                end
            end
        end
    end

    previewSpellID = specPick or anyPick
    return previewSpellID
end

-- The worst-case (longest) callout form, so the layout is sized against the
-- widest line it will ever have to show.
local function PreviewText(withLink)
    local id = PreviewSpellID()
    if id then
        local link = withLink and C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(id)
        if link then return link .. " will be ready in 0:12!" end
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        local name = info and info.name
        if name then
            return ("|cff71d5ff[%s]|r will be ready in 0:12!"):format(name)
        end
    end
    -- no spellbook yet (very early login): a linkless line still previews the
    -- layout correctly, and the next refresh picks up the real spell
    return "|cff71d5ff[Your Cooldown]|r will be ready in 0:12!"
end
local function ShowPreviewEntry()
    RemovePreviewEntries()
    if #entries > 0 then Render(); return end  -- real pings on screen win
    AddEntry(PreviewText(true), UnitName("player"), UnitGUID and UnitGUID("player") or nil, true)
end

-- ── receive + init ───────────────────────────────────────────────────────────
-- SECRECY PROBE. Collapsing duplicate pings into one "x4" line needs to compare
-- sender+payload, and nothing in the API can compare two secrets (C_StringUtil
-- is all one-way transforms; there is no equality or hash helper). So whether
-- that feature can ship AT ALL comes down to one question: are these two values
-- secret while you are in an instance/combat?
--
-- Recording it costs nothing -- issecretvalue() is the one thing you may always
-- ask about a secret -- and settles it with evidence instead of assumption.
-- Read it back with /arcping secrets after taking pings in an M+.
local pingSecrecy = { seen = 0 }
local function NotePingSecrecy(text, sender, guid)
    pingSecrecy.seen      = pingSecrecy.seen + 1
    pingSecrecy.combat    = InCombatLockdown() and true or false
    pingSecrecy.instance  = IsInInstance and select(1, IsInInstance()) or false
    pingSecrecy.textSecret   = issecretvalue and issecretvalue(text) or false
    pingSecrecy.senderSecret = issecretvalue and issecretvalue(sender) or false
    pingSecrecy.guidPresent  = guid ~= nil
    pingSecrecy.at = GetTime()
end

-- Which "Show In" switch covers where the player is standing.
local function CurrentContent()
    local _, instanceType = GetInstanceInfo()
    if instanceType == "party" then
        local cm = C_ChallengeMode
        if cm and cm.IsChallengeModeActive and cm.IsChallengeModeActive() then
            return "showInMythicPlus"
        end
        return "showInDungeon"
    elseif instanceType == "raid" then      return "showInRaid"
    elseif instanceType == "pvp" then       return "showInBattleground"
    elseif instanceType == "arena" then     return "showInArena"
    elseif instanceType == "scenario" then  return "showInScenario"
    end
    return "showInWorld"
end

local function FeedAllowedHere()
    return Cfg(CurrentContent()) ~= false
end

-- Content type changed, so the Show In answer may have. Its own frame rather
-- than boot's: boot re-runs its whole login sequence for every event it gets.
local zoneEv = CreateFrame("Frame")
zoneEv:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneEv:RegisterEvent("ZONE_CHANGED_NEW_AREA")
zoneEv:RegisterEvent("CHALLENGE_MODE_START")
zoneEv:RegisterEvent("CHALLENGE_MODE_COMPLETED")
zoneEv:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
zoneEv:SetScript("OnEvent", function()
    if ApplyAll then ApplyAll() end
end)

local evFrame = CreateFrame("Frame")
evFrame:SetScript("OnEvent", function(_, _, text, sender, _a3, _a4, _a5, _a6, _a7, _a8, _a9, _a10, _lineID, guid)
    -- arg11 = LINE COUNTER (not a ping type -- it fooled us once; leave it).
    -- arg12 = sender GUID: nil on current builds; kept as the future
    -- combat path to class/name when the sender string is secret.
    NotePingSecrecy(text, sender, guid)
    AddEntry(text, sender, guid)
end)

SLASH_ARCPINGSECRETS1 = "/arcping"
SlashCmdList["ARCPINGSECRETS"] = function(msg)
    local sub = (msg or ""):lower():match("^%s*(%a*)")
    -- a slash command, because "/dump ArcUI_PingDebug()" loses its closing
    -- paren to some chat inputs and errors on <eof>
    if sub == "debug" then
        if _G.ArcUI_PingDebug then _G.ArcUI_PingDebug() end
        return
    end
    if sub ~= "secrets" then
        print("|cff00ccffArc Pings|r: /arcping debug  -- ping keys + scope dump")
        print("|cff00ccffArc Pings|r: /arcping secrets  -- report ping payload secrecy")
        return
    end
    if pingSecrecy.seen == 0 then
        print("|cff00ccffArc Pings|r: no pings received yet this session.")
        return
    end
    print(("|cff00ccffArc Pings|r  pings seen: %d   last %.1fs ago")
        :format(pingSecrecy.seen, GetTime() - (pingSecrecy.at or 0)))
    print(("  context:  combat=%s  instance=%s")
        :format(tostring(pingSecrecy.combat), tostring(pingSecrecy.instance)))
    print(("  payload text  secret = %s"):format(
        pingSecrecy.textSecret and "|cffff5555YES|r" or "|cff55ff55no|r"))
    print(("  sender name   secret = %s"):format(
        pingSecrecy.senderSecret and "|cffff5555YES|r" or "|cff55ff55no|r"))
    print(("  sender GUID   present = %s"):format(
        pingSecrecy.guidPresent and "|cff55ff55yes|r" or "|cffff5555no|r"))
    if pingSecrecy.textSecret or pingSecrecy.senderSecret then
        print("  |cffff5555Collapse cannot ship|r -- no way to compare secrets.")
    else
        print("  |cff55ff55Collapse is viable in this context.|r")
    end
end

ApplyAll = function()
    if STANDALONE_LOADED then
        if win then win:Hide() end
        evFrame:UnregisterAllEvents()
        -- pingable icons are ArcUI-only (the standalone doesn't own the
        -- icons), so dormancy must NOT take them down
        Pings.RefreshPingable()
        return
    end
    -- the feed is OFF here if this content type is switched off: stop
    -- listening as well as hiding, so nothing queues up behind the scenes
    local live = Cfg("enabled") and HAS_ACTION_PINGS and FeedAllowedHere()
    if live then
        evFrame:RegisterEvent("CHAT_MSG_PING")
        WarnIfBlizzSettingsOff()
    else
        evFrame:UnregisterAllEvents()
    end
    if live then
        local w = EnsureWindow()
        local pos = DB().pos
        -- SCALE WITHOUT DRIFT: the saved offsets are in WINDOW units, so a
        -- scale change multiplies the window's distance from screen center
        -- (it slid toward a corner). Re-express the stored offsets in the new
        -- scale first -- the window then stays exactly where it is on screen.
        local newScale = tonumber(Cfg("windowScale")) or 1
        if newScale <= 0 then newScale = 1 end
        local oldScale = w._appliedScale or newScale
        if pos and oldScale ~= newScale then
            local f = oldScale / newScale
            pos[1] = (pos[1] or 0) * f
            pos[2] = (pos[2] or 0) * f
            if pos.top then pos.top = pos.top * f end
            if pos.bottom then pos.bottom = pos.bottom * f end
        end
        w._appliedScale = newScale
        w:SetScale(newScale)
        w:ClearAllPoints()
        -- anchor by the STABLE edge for the grow direction; the center form
        -- is only a legacy/first-run fallback (Render converts it to an edge)
        if pos and Cfg("newestOnTop") and pos.top then
            w:SetPoint("TOP", UIParent, "CENTER", pos[1], pos.top)
        elseif pos and not Cfg("newestOnTop") and pos.bottom then
            w:SetPoint("BOTTOM", UIParent, "CENTER", pos[1], pos.bottom)
        elseif pos then
            w:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
        else
            -- first-run default: center-top of the screen
            w:SetPoint("TOP", UIParent, "TOP", 0, -100)
        end
        w:EnableMouse(CanDrag())
        w:SetFrameStrata(Cfg("strata"))
        -- chromeless by default: bg/border only when opted in; the cyan
        -- hairline always shows while unlocked (placement aid)
        local cbg = Cfg("colBg")
        w:SetBackdropColor(cbg[1], cbg[2], cbg[3], Cfg("showBackground") and Cfg("bgAlpha") or 0)
        -- border lives on the overlay (above rows -- content can't cover it)
        w:SetBackdropBorderColor(0, 0, 0, 0)
        -- border: the cyan hairline only while unlocked (drag aid). Locked =
        -- purely the user's choice -- panel-open never forces a border on,
        -- and the user's Border Color always wins when Show Border is on.
        if not Cfg("locked") then
            w.edge:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
        elseif Cfg("showBorder") then
            local cbo = Cfg("colBorder")
            w.edge:SetBackdropBorderColor(cbo[1], cbo[2], cbo[3], 1)
        else
            w.edge:SetBackdropBorderColor(0, 0, 0, 0)
        end
        -- title: floats above the window while unlocked or the panel is open
        w._titleWanted = (not Cfg("locked") or panelOpen) and Cfg("showTitle") ~= false
        w.titleHolder:SetFrameStrata(Cfg("strata"))
        w.titleHolder:SetScale(newScale)
        w.titleHolder:SetShown(w._titleWanted and w:IsShown())
        w._arcPosDirty = true   -- tell Render the stored position wins this pass
        Render()
    elseif win then
        win:Hide()
    end
    Pings.RefreshPingable()
end
Pings.ApplyAll = function() ApplyAll() end

local designerNotify   -- fwd: refreshes the Layout Designer canvas when open
local PKApply          -- fwd: Ping Keys re-arm (defined below; nil until then)

local function SetCfg(key, val)
    if PK_CHAR_ONLY[key] then
        DB()[key] = val
    else
        -- Editing in a narrower scope CAPTURES the setting: from here on this
        -- char/spec keeps its own value and stops following the account one.
        -- Clearing the patch puts it back on the leash.
        ScopedStore()[key] = val
    end
    ApplyAll()
    if designerNotify then designerNotify() end
    if PKApply then PKApply() end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PING KEYS — hold your ping key, press a tracked spell's OWN keybind, and
-- that key pings the spell instead of casting it.
--
-- /pingspell is a SECURE slash command (Blizzard registers it through
-- CheckAddSecureSlashCommand), so it only fires from a SecureActionButton's
-- macrotext. RunMacroText from ordinary addon Lua does nothing at all.
--
-- COMBAT-FIRST (the hard rule): the binding swap has to happen the instant the
-- ping key goes down, which is mid-fight. SetOverrideBindingClick and
-- SetAttribute are both blocked there, so the swap runs INSIDE a secure
-- snippet, where HANDLE:SetBindingClick / HANDLE:ClearBindings are legal. Every
-- Lua-side write (relay macrotext, the attribute list the snippet reads, the
-- ping key's own override binding) happens OUT of combat only, and any edit
-- made mid-fight is deferred to PLAYER_REGEN_ENABLED.
--
-- Binding ownership is split on purpose: pkBindOwner owns the ping key's
-- override binding (written from Lua), the handler owns the swapped spell
-- bindings (written from the snippet). One frame owning both would have the
-- Lua-side ClearOverrideBindings and the snippet-side ClearBindings fighting
-- over the same list.
--
-- DORMANCY: unlike pingable icons (which only ArcUI can provide), this feature
-- exists in the standalone too and both would grab the SAME key. ArcUI's copy
-- stays fully inert whenever the standalone Arc Pings addon is loaded.
-- ═══════════════════════════════════════════════════════════════════════════

local PK_MAX = 12   -- tracked spells (also the relay-button pool size)

-- Dormant when the standalone owns the feature: both addons ship Ping Keys and
-- would grab the SAME key, unlike pingable icons which only ArcUI can provide.
local function PKUsable() return HAS_ACTION_PINGS and not STANDALONE_LOADED end

local PK_ALL_MAX = 60   -- relay ceiling for "any spell" mode (5 bars of 12)

local pkBindOwner, pkAlwaysOwner
local pkRelays = {}
local pkDirty  = false

-- fwd: defined in the SELECT MODE block below, needed by PKApply above it
local PKCollectButtons, PKButtonSubject, PKSubjectInfo, PKPingLine
local PKLiveSpellID
local ACNotify   -- assigned with the options table, far below

-- A flip of Auto-Ping is a deliberate act mid-fight, so it needs to be visible
-- without looking at the options panel. UIErrorsFrame is the standard spot for
-- a one-line status flash and it works in combat.
local function PKAutoNotify(on)
    local msg = on and "Auto-Ping ON" or "Auto-Ping OFF"
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        if on then
            UIErrorsFrame:AddMessage("|cff33ff99Arc Pings:|r " .. msg, 0.2, 1.0, 0.6, 1, 3)
        else
            UIErrorsFrame:AddMessage("|cffff5555Arc Pings:|r " .. msg, 1.0, 0.35, 0.35, 1, 3)
        end
    end
    if PlaySound and SOUNDKIT then
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                     or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
    end
end

local function PKList()
    local db = DB()
    if type(db.pkSpells) ~= "table" then db.pkSpells = {} end
    return db.pkSpells
end

-- ── WHICH BINDING COMMAND DOES THIS BUTTON ANSWER TO? ───────────────────────
-- There is no single field. Reading only `bindingAction/commandName/
-- keyBoundTarget` is why Bartender4 never worked: BT4 hands its binding command
-- to LibActionButton as `buttonConfig.keyBoundTarget`, and LAB DEEP-COPIES that
-- into `button.config.keyBoundTarget` (Generic:UpdateConfig) -- the plain
-- `button.keyBoundTarget` field is never written, so every BT4 button resolved
-- to nil and silently armed nothing.
--
-- And even config.keyBoundTarget is not enough: BT4 only maps bars
-- 1,3,4,5,6,13,14,15 to ACTIONBUTTON-style commands. Bars 2 and 7-10 leave it
-- FALSE and are reachable only as "CLICK BT4Button<n>:Keybind".
--
-- So: build every command this button could answer to, most authoritative
-- first, and take the first one the game has a key for. The order mirrors
-- LibActionButton's own GetHotkey (keyBoundTarget, then the CLICK form), so we
-- agree with the bar addon by construction instead of by guess.
local PKKeyForButton
do
    local function PushCmd(t, seen, v)
        if type(v) ~= "string" or v == "" or seen[v] then return end
        seen[v] = true
        t[#t + 1] = v
    end

    local function ButtonCommands(btn)
        if not btn then return nil end
        local out, seen = {}, {}
        local cfg = type(btn.config) == "table" and btn.config or nil
        -- LibActionButton's own answer. Gated on cfg so we never call the method
        -- on a Blizzard frame that happens to have a same-named field.
        if cfg and type(btn.GetBindingAction) == "function" then
            PushCmd(out, seen, btn:GetBindingAction())
        end
        PushCmd(out, seen, btn.bindingAction)          -- Blizzard
        PushCmd(out, seen, btn.commandName)            -- Blizzard bar init, EllesmereUI
        PushCmd(out, seen, btn.keyBoundTarget)         -- ElvUI (direct field)
        PushCmd(out, seen, cfg and cfg.keyBoundTarget) -- LAB config (Bartender4, ElvUI)
        local name = btn.GetName and btn:GetName()
        if name then
            local cb = (cfg and type(cfg.keyBoundClickButton) == "string")
                       and cfg.keyBoundClickButton
            PushCmd(out, seen, ("CLICK %s:%s"):format(name, cb or "Keybind"))
            PushCmd(out, seen, ("CLICK %s:Keybind"):format(name))
            PushCmd(out, seen, ("CLICK %s:LeftButton"):format(name))
        end
        return out
    end

    -- key, command. Returns the command even when unbound, so callers can store
    -- a stable one to re-resolve against later.
    function PKKeyForButton(btn)
        local cmds = ButtonCommands(btn)
        if not cmds or #cmds == 0 then return nil, nil end
        for i = 1, #cmds do
            local k = GetBindingKey(cmds[i])
            if k and k ~= "" then return k, cmds[i] end
        end
        return nil, cmds[1]
    end
end

-- Fallback for entries with no source button (Add-By-ID) or whose button moved:
-- find the spell on ANY discovered bar button and read that button's key.
local function PKAutoKey(spellID)
    local btns = PKCollectButtons and PKCollectButtons()
    if not btns then return nil end
    for i = 1, #btns do
        local sid = PKButtonSubject(btns[i])
        if sid == spellID then
            local k = PKKeyForButton(btns[i])
            if k then return k end
        end
    end
    return nil
end

-- the key a tracked entry actually answers to, best source first:
--   1. a manual override the user typed
--   2. the BINDING COMMAND captured when they picked the spell off a bar --
--      resolved live, so rebinding the key updates us for free, and it works
--      for ElvUI/Bartender buttons that PKAutoKey's name scan cannot see
--   3. a fresh scan of Blizzard's bars (entries added by spell ID)
-- The BAR key this entry lives on. Note there is deliberately no override here
-- any more: the per-spell override is a PING key (which modifier key activates
-- this spell), not a spell key. Overriding the spell key silently disconnected
-- the real bar key, which is the bug Arc hit.
-- A stored button name can point at a frame a bar addon has since REPLACED:
-- still in _G, but statehidden with a frozen .action. Reading it yields a stale
-- spell, and GetBindingKey on its command yields a real key for the WRONG
-- spell. Treat it as gone so the fallback chain finds the live button instead.
local function PKLiveButton(name)
    local btn = name and _G[name]
    if type(btn) ~= "table" then return nil end
    if btn.GetAttribute and btn:GetAttribute("statehidden") then return nil end
    return btn
end

-- LIVE BUTTON FIRST. The stored command is a snapshot taken when the spell was
-- picked; the button itself is the bar addon's current truth, so a rebind, a
-- bar reconfigure or a profile switch is picked up for free.
local function PKKeyFor(entry)
    local btn = PKLiveButton(entry.btn)
    if btn then
        local k = PKKeyForButton(btn)
        if k then return k end
    end
    if entry.cmd then
        local k = GetBindingKey(entry.cmd)
        if k and k ~= "" then return k end
    end
    return PKAutoKey(entry.id)
end

-- ── SPEC / BAR-CONTENT GUARD ────────────────────────────────────────────────
-- A binding command SURVIVES a spec change; the spell in its slot does not.
-- Pick Doom Winds on Enhancement (MULTIACTIONBAR4BUTTON4 = G), switch to Resto,
-- and GetBindingKey still hands back G -- but that slot now holds Healing Rain.
-- Arming anyway overrides G with a relay that casts DOOM WINDS, so the player
-- cannot cast what is actually on their bar and gets a ping for a spell they do
-- not have. Always-mode is the damaging one: it binds unconditionally.
--
-- So before arming anything that hijacks a BAR key, check the button still
-- holds this entry's subject. Compared through PKLiveSpellID so an override
-- pair (base captured, override live or vice versa) is not a false negative.
--
-- Entries with no source button (Add-By-ID) have nothing to verify and are
-- allowed through -- their key is either a manual override or a live bar scan
-- that already matched on spell id.
local function PKEntryMatchesBar(entry)
    if not entry then return false end
    local btn = PKLiveButton(entry.btn)
    if not btn then return true end   -- no live source button = nothing to verify
    local sid = PKButtonSubject(btn)
    if not sid then return false end            -- slot emptied in this spec
    if sid == entry.id then return true end
    if entry.kind == "item" then return false end
    return PKLiveSpellID(sid) == PKLiveSpellID(entry.id)
end

-- Which ping key activates this entry: its own override, else the global one.
local function PKPingKeyFor(entry)
    local k = entry and entry.pingKey
    if k and k ~= "" then return k end
    local g = Cfg("pkKey")
    return (g and g ~= "") and g or nil
end

-- relays live 1px offscreen and SHOWN on purpose: a binding click is delivered
-- to the button regardless, but a shown button is the pattern every secure
-- relay addon uses and costs nothing
-- ── PRESS GATE ──────────────────────────────────────────────────────────────
-- "Ping every Nth press". A TIME-based throttle is impossible: the restricted
-- environment has no clock (RestrictedEnvironment.lua exposes math/string plus
-- macro conditionals, nothing else) and Lua cannot write a secure button's
-- attributes in combat. Counting, though, is just arithmetic -- legal anywhere.
--
-- This pre-click snippet runs BEFORE the button's own OnClick, so it picks
-- which of two pre-baked macrotexts that same click will run:
--   pkFull     = cast + ping
--   pkCastOnly = cast, no ping
-- The cast line is in BOTH, so a suppressed ping can never eat a keypress --
-- the same property that makes Blizzard's own ping cooldown safe.
--
-- Honest limit, by construction: this counts PRESSES, not seconds. The counter
-- does not decay, so with N=2 it is always the even-numbered press that pings,
-- however far apart they are.
-- HANDS OFF unless this relay is a gated always-relay. Relays are POOLED, so a
-- hold-mode relay (macrotext = ping line only, no pkFull) shares the pool -- and
-- blanking or overwriting its macrotext here would silently kill the ping.
--
-- NO TIMEOUT IS POSSIBLE. Tested 2026-08-09, do not try this again:
--
-- The snippet has no clock, so the idea was to let Lua do the timing (C_Timer
-- works in combat) and publish the verdict on a PLAIN unprotected frame that
-- the snippet reads across a frame ref -- lockdown only guards PROTECTED
-- frames, so Lua can write a plain one mid-combat.
--
-- The read side is barred. RestrictedFrames.lua:79-85 resolves a frame handle
-- only when `isProtected or IsProtected(frame) or not InCombatLockdown()`, so
-- an unprotected frame throws "Invalid frame handle" the moment you are in
-- combat -- and the throw aborts the whole snippet, killing the press count
-- with it. Making the clock protected instead just moves the wall: then Lua
-- cannot write it in combat. That catch-22 IS the security boundary.
--
-- NO COOLDOWN- OR TIME-BASED GATING IS POSSIBLE IN COMBAT. Four attempts, all
-- tested in-game 2026-08-09. In combat the two domains are sealed from each
-- other, and every design needs one of them to reach across:
--
--   Lua -> PROTECTED frame   : blocked ("ADDON_ACTION_BLOCKED ... SetAttribute",
--                              and likewise SetCooldownFromDurationObject)
--   snippet -> UNPROTECTED   : blocked ("Invalid frame handle")
--
-- The blocked-function list in the API docs does NOT tell you this: SetAttribute
-- carries no HasRestrictions flag, yet Relay:SetAttribute() is refused in combat.
-- Protection is a property of the FRAME, not of the function. Do not reason from
-- the doc flags again.
--
-- Detecting readiness was never the problem -- the shadow-Cooldown trick in
-- ArcUI_CooldownReminder does it perfectly and non-secretly. DELIVERING the
-- verdict to whatever picks the macrotext is what is impossible.
--
-- Beware the false positive: at a target dummy you drop combat constantly, so a
-- broken version looks like it works. It freezes at the pull in a real fight.
--
-- The four dead ends, so nobody re-walks them:
--
--   1. Plain frame + our own C_Timer. Lua wrote it fine (proved: luaSays=true),
--      but the snippet threw "Invalid frame handle" in combat and the throw
--      ABORTED the whole snippet, killing the press count with it.
--   2. Blizzard's `button.cooldown`. A live dump showed
--      MultiBarLeftButton4Cooldown with isProtected=FALSE -- the button is
--      protected, its cooldown child is not -- so it resolves no better.
--   3. Our own Cooldown widget with SecureHandlerBaseTemplate, so it IS
--      explicitly protected and readable. Then Lua can no longer feed it:
--      "ADDON_ACTION_BLOCKED ... SetCooldownFromDurationObject".
--   4. Inverted it: keep the shadow UNPROTECTED (feedable, and OnCooldownDone
--      gives the ready transition for free), let LUA write the relay's
--      macrotext so no snippet ever reads anything. Blocked too --
--      "ArcUIPingRelay1:SetAttribute()" is protected in combat.
--
-- Protecting the clock so the snippet may read it is exactly what stops us
-- filling it; leaving it unprotected is exactly what stops the snippet reading
-- it; and writing the answer straight onto the relay is refused outright. No
-- frame is both, and there is no third party to carry it across.
--
-- So this gate counts PRESSES and nothing else. The count does not decay.
local PK_PRESS_GATE = [=[
    local full = self:GetAttribute("pkFull")
    if not full then return end
    local castOnly = self:GetAttribute("pkCastOnly") or full

    -- press count (no decay -- see the wall above)
    local every = self:GetAttribute("pkEvery") or 1
    if every <= 1 then
        self:SetAttribute("macrotext", full)
        return
    end
    local n = (self:GetAttribute("pkPress") or 0) + 1
    if n >= every then n = 0 end
    self:SetAttribute("pkPress", n)
    -- n wrapped back to 0 on THIS press => this is the Nth => ping
    if n == 0 then
        self:SetAttribute("macrotext", full)
    else
        self:SetAttribute("macrotext", castOnly)
    end
]=]

local pkGateHeader

local function PKRelay(i)
    local r = pkRelays[i]
    if not r then
        r = CreateFrame("Button", "ArcUIPingRelay" .. i, UIParent, "SecureActionButtonTemplate")
        r:SetSize(1, 1)
        r:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
        r:RegisterForClicks("AnyDown")
        r:SetAttribute("type", "macro")
        r:SetAttribute("macrotext", "")
        -- the wrap needs an explicitly-protected header frame to run against
        if not pkGateHeader then
            pkGateHeader = CreateFrame("Frame", "ArcUIPingGateHeader", UIParent,
                "SecureHandlerBaseTemplate")
        end
        SecureHandlerWrapScript(r, "OnClick", pkGateHeader, PK_PRESS_GATE)

        -- PLAIN frame on purpose -- see the clock note above. Lua writes it in
        -- combat; the snippet reads it. The ref is set once, out of combat.
        pkRelays[i] = r
    end
    -- Pooled: wipe the previous owner's gate data on every claim. Without this a
    -- hold-mode entry reusing an always-mode slot would inherit its pkFull and
    -- ping the wrong spell.
    r:SetAttribute("pkFull", nil)
    r:SetAttribute("pkCastOnly", nil)
    r:SetAttribute("pkEvery", 1)
    r:SetAttribute("pkPress", 0)
    return r
end


-- runs in the RESTRICTED environment, so it is legal in combat. It reads the
-- key/relay pairs off its own attributes because a snippet cannot see addon
-- Lua tables.
--
-- The PAGE GUARD is what keeps "Any Spell" mode honest. Relay macrotext is
-- baked from what each button held at bake time, and baking needs Lua, which is
-- locked in combat. If your bar pages mid-fight (druid forms, warrior stances,
-- vehicles) the baked text is stale, so rather than ping the WRONG spell the
-- snippet refuses to bind anything until the bar returns to the baked state or
-- combat ends. Correct or silent, never wrong.
local PK_SNIPPET = [=[
    if down then
        if self:GetAttribute("pkGuard") then
            local baked = self:GetAttribute("pkBakedState")
            local live  = self:GetAttribute("pkLiveState")
            if baked and live and baked ~= live then return end
        end
        local n = self:GetAttribute("pkCount") or 0
        for i = 1, n do
            local k = self:GetAttribute("pkKey" .. i)
            local r = self:GetAttribute("pkRelay" .. i)
            if k and r then
                self:SetBindingClick(true, k, r)
            end
        end
    else
        self:ClearBindings()
    end
]=]

-- the bar state the relays were baked against; any change invalidates them
local PK_STATE_DRIVER =
    "[overridebar]o;[vehicleui]v;[possessbar]p;[shapeshift]s;"
    .. "[bar:2]2;[bar:3]3;[bar:4]4;[bar:5]5;[bar:6]6;1"
local PK_STATE_SNIPPET = [=[ self:SetAttribute("pkLiveState", newstate) ]=]

-- HOLDER POOL, one per distinct ping key. Spells can each nominate their own
-- ping key, so several may be live at once; each holder owns only the spells
-- assigned to its key, and its snippet binds only those.
local pkHolders, pkHolderN = {}, 0

local function PKHolder(pingKey)
    local h = pkHolders[pingKey]
    if h then return h end
    pkHolderN = pkHolderN + 1
    -- _onclick needs ClickTemplate and _onstate-* needs StateTemplate. With
    -- Click alone the page-guard snippet never ran, so pkLiveState never
    -- updated and the guard was dead weight.
    h = CreateFrame("Button", "ArcUIPingKeyHolder" .. pkHolderN, UIParent,
        "SecureHandlerClickTemplate,SecureHandlerStateTemplate")
    h:SetSize(1, 1)
    h:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
    h:RegisterForClicks("AnyDown", "AnyUp")
    h:SetAttribute("_onclick", PK_SNIPPET)
    h:SetAttribute("_onstate-pkpage", PK_STATE_SNIPPET)
    RegisterStateDriver(h, "pkpage", PK_STATE_DRIVER)
    pkHolders[pingKey] = h
    return h
end

local function PKEnsureOwners()
    pkBindOwner   = pkBindOwner   or CreateFrame("Frame")
    pkAlwaysOwner = pkAlwaysOwner or CreateFrame("Frame")
end

-- the current bar state, read the same way the state driver reports it
local function PKBarState()
    if HasOverrideActionBar and HasOverrideActionBar() then return "o" end
    if UnitHasVehicleUI and UnitHasVehicleUI("player") then return "v" end
    if IsPossessBarVisible and IsPossessBarVisible() then return "p" end
    local form = GetShapeshiftForm and GetShapeshiftForm()
    if form and form > 0 then return "s" end
    local page = GetActionBarPage and GetActionBarPage() or 1
    return tostring(page)
end

-- how many tracked spells currently resolve to a key (options panel status)
-- entries that would actually arm right now. Always mode needs the source
-- BUTTON too (its relay /clicks it to reproduce the cast), so an entry added by
-- spell ID counts in hold mode but not in always mode -- the status line has to
-- reflect that or it promises something that never fires.
-- An entry stays in the list while DISABLED so its key override and mode
-- survive being toggled off -- that is what separates "Enable Ping" (temporary)
-- from "Remove" (permanent). enabled == nil means enabled: entries created
-- before the flag existed keep working.
local function PKEntryOn(e) return e and e.enabled ~= false end

-- Each mode needs a different key to exist, so the check is mode-aware.
-- (PKEntryMode is defined further down, so the modes are read directly here.)
local function PKEntryArms(e)
    if not (e and e.id and PKEntryOn(e)) then return false end
    if e.mode == "own" then
        -- own key mode needs only its dedicated key; no bar key, no ping key
        return e.ownKey ~= nil and e.ownKey ~= ""
    end
    -- the other two ride the spell's action bar key
    if not PKKeyFor(e) then return false end
    if e.mode == "always" then return true end
    -- hold mode also needs a ping key to hold (its own, or the global one)
    return PKPingKeyFor(e) ~= nil
end

local function PKResolvedCount()
    local list, n = PKList(), 0
    for i = 1, #list do
        if PKEntryArms(list[i]) then n = n + 1 end
    end
    return n
end

-- how many entries are armed right now, and why not (options status line)
local pkArmed, pkSkipped = 0, 0

-- an entry's own mode: "key" (ping key + its key) or "always" (pings on every
-- press, no modifier). Per-entry, so one spell can always announce itself while
-- the rest stay behind the ping key.
local function PKEntryMode(e)
    if e.mode == "always" then return "always" end
    if e.mode == "own" then return "own" end
    return "key"
end

-- What an Always relay has to run to reproduce the user's own cast.
--
-- /click <button> is right for a button holding a SPELL or an ITEM: it keeps
-- paging, override spells and range/target handling as Blizzard's own button
-- does them. It is WRONG for a button holding a MACRO, because WoW refuses to
-- run a macro from inside another macro -- the /click silently did nothing and
-- only the ping fired, which is exactly the "it pings but never casts" report.
-- For those we inline the macro's OWN body instead, read fresh at bake time so
-- edits to the macro are picked up without re-selecting it.
-- NAME IS NOT UNIQUE. An account macro and a character macro can share a name
-- (a live dump had "Pve" as both a Demon Hunter Sigil macro at index 59 and the
-- Shaman's own Wind Shear macro), and neither GetMacroIndexByName nor a plain
-- name scan can tell them apart -- both just return whichever comes first, so
-- the relay ran a different class's macro.
--
-- So disambiguate against the SLOT: among every macro sharing the name, prefer
-- the one whose resolved spell matches the slot's, then the one whose icon
-- matches, and only then fall back to first-by-name.
local PK_MACRO_BASE = 120   -- Constants.MacroConsts.MAX_ACCOUNT_MACROS
local function PKMacroIndexForSlot(slot)
    if type(slot) ~= "number" then return nil end
    local name = GetActionText and GetActionText(slot)
    if not name or name == "" then return nil end
    if not (GetNumMacros and GetMacroInfo) then return nil end
    local _t, wantSpell = GetActionInfo(slot)
    local wantTex = GetActionTexture and GetActionTexture(slot)
    local acct, char = GetNumMacros()
    local byName, bySpell, byTex
    local function scan(from, to)
        for i = from, to do
            local n, tex = GetMacroInfo(i)
            if n == name then
                byName = byName or i
                if wantSpell and GetMacroSpell and GetMacroSpell(i) == wantSpell then
                    bySpell = bySpell or i
                end
                if wantTex and tex == wantTex then byTex = byTex or i end
            end
        end
    end
    scan(1, acct or 0)
    scan(PK_MACRO_BASE + 1, PK_MACRO_BASE + (char or 0))
    return bySpell or byTex or byName
end

-- Talent overrides swap what a bar key really casts (Doom Winds <-> Ascendance),
-- and the swap happens long after we baked the macrotext. An entry captured
-- while the override was up stores the OVERRIDE spell, so "/cast Ascendance"
-- casts nothing once the talent is dropped -- the key pings but refuses to fire,
-- which is exactly the reported bug.
--
-- Casting the BASE spell fixes it in both directions: WoW routes /cast <base>
-- to whichever spell currently overrides it, so one line stays correct through
-- the swap and never needs rewriting. That matters because rewriting a secure
-- macrotext in combat is impossible -- this way there is nothing to rewrite.
--
-- Returns nil when the entry already IS the base, so the caller keeps its own
-- name and nothing changes for the overwhelmingly common case.
local function PKBaseSpellName(id)
    if type(id) ~= "number" then return nil end
    if not (C_Spell and C_Spell.GetBaseSpell) then return nil end
    local base = C_Spell.GetBaseSpell(id)
    if type(base) ~= "number" or base <= 0 or base == id then return nil end
    local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(base)
    return info and info.name or nil
end

local function PKCastLines(e)
    -- MACRO buttons: inline the macro's own body. A macro cannot /click another
    -- macro (WoW blocks nested macro execution), and the body preserves every
    -- conditional the user wrote.
    local btn = e.btn and _G[e.btn]
    if btn then
        local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
        if type(slot) == "number" and HasAction(slot) then
            local aType = GetActionInfo(slot)
            if aType == "macro" then
                local idx = PKMacroIndexForSlot(slot)
                if idx and GetMacroInfo then
                    local _n, _t, body = GetMacroInfo(idx)
                    if type(body) == "string" and body ~= "" then
                        return (body:gsub("%s+$", ""))
                    end
                end
            end
        end
    end
    -- Everything else casts BY NAME rather than /click-ing the source button.
    --
    -- /click looked right (it inherits paging, overrides and targeting) but is
    -- broken under modifiers: ActionButton's OnClick early-returns when
    -- IsModifiedClick("PICKUPACTION") -- SHIFT by default -- so with bars locked
    -- a shift-bound spell did nothing, and with bars unlocked it picked the
    -- spell up off the bar instead. That is why SHIFT-bound spells pinged but
    -- never cast.
    --
    -- Casting by name sidesteps the button entirely, and it means an entry no
    -- longer needs a source button at all: an Add-By-ID spell with a Key
    -- Override can now use Every Cast too.
    local nm = PKSubjectInfo(e)
    if not nm or nm == "" then return nil end
    if e.kind == "item" then return "/use " .. nm end
    -- base name, not the stored one -- see PKBaseSpellName above
    return "/cast " .. (PKBaseSpellName(e.id) or nm)
end

-- ── AUTO-PING TOGGLE ───────────────────────────────────────────────────────
-- "Every time I cast it" spells are handy in M+ and noise in a raid, so the
-- whole always-mode layer can be switched off with one key, mid-fight.
--
-- That forces a design point: the always bindings must be owned by a SNIPPET,
-- not by Lua. Lua cannot ClearOverrideBindings in combat, and a snippet's
-- ClearBindings only clears what the HANDLE owns -- mixing the two would leave
-- half the bindings live. So every always binding is applied inside
-- pkAutoApply, and both entry points run that same snippet:
--   * out of combat, Lua sets the attributes then Hide()/Show() -> _onshow
--   * in combat, the toggle key's _onclick flips the flag -> RunAttribute
local PK_AUTO_APPLY = [=[
    self:ClearBindings()
    if not self:GetAttribute("pkAutoOn") then return end
    local n = self:GetAttribute("pkAutoCount") or 0
    for i = 1, n do
        local k = self:GetAttribute("pkAutoKey" .. i)
        local r = self:GetAttribute("pkAutoRelay" .. i)
        if k and r then
            self:SetBindingClick(true, k, r)
        end
    end
]=]

local PK_AUTO_TOGGLE = [=[
    if down then
        self:SetAttribute("pkAutoOn", not self:GetAttribute("pkAutoOn"))
        self:RunAttribute("pkAutoApply")
    end
]=]

local pkAutoHolder

local function PKAutoHolder()
    if pkAutoHolder then return pkAutoHolder end
    pkAutoHolder = CreateFrame("Button", "ArcUIPingAutoHolder", UIParent,
        -- BOTH templates: ClickTemplate wires _onclick (the toggle key), but
        -- _onshow is ONLY honoured by ShowHideTemplate. With Click alone the
        -- apply snippet never ran and no always-mode spell ever bound.
        "SecureHandlerClickTemplate,SecureHandlerShowHideTemplate")
    pkAutoHolder:SetSize(1, 1)
    pkAutoHolder:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
    pkAutoHolder:RegisterForClicks("AnyDown")
    pkAutoHolder:SetAttribute("pkAutoApply", PK_AUTO_APPLY)
    pkAutoHolder:SetAttribute("_onclick", PK_AUTO_TOGGLE)
    pkAutoHolder:SetAttribute("_onshow", "self:RunAttribute('pkAutoApply')")

    -- THE SNIPPET FLIPS THIS ATTRIBUTE AND LUA HAS TO HEAR ABOUT IT.
    -- Previously the only sync was on PLAYER_REGEN_ENABLED, while PKApply seeds
    -- the holder FROM the saved value -- so an out-of-combat press was never
    -- stored, and the next PKApply (spec change, rebind, bar edit) pushed the
    -- stale value back over it. That is the "auto-ping turns itself off"
    -- report, and it silences every always-mode spell when it happens.
    --
    -- OnAttributeChanged fires for snippet writes too, in combat and out, so
    -- the saved value can no longer drift from the live one. Writing a Lua
    -- table is not a protected action, so this is safe mid-combat.
    pkAutoHolder:SetScript("OnAttributeChanged", function(_self, name, value)
        if name ~= "pkautoon" then return end   -- names arrive lowercased
        local on = value and true or false
        if (Cfg("pkAutoOn") ~= false) == on then return end   -- no real change
        DB().pkAutoOn = on
        PKAutoNotify(on)
        if ACNotify then ACNotify() end
    end)
    return pkAutoHolder
end

-- Is auto-ping currently live? Read from the holder when it exists, because the
-- toggle key can have flipped it in combat without Lua ever hearing about it.
local function PKAutoOn()
    if pkAutoHolder then
        return pkAutoHolder:GetAttribute("pkAutoOn") and true or false
    end
    return Cfg("pkAutoOn") ~= false
end

-- Always entries: the entry's own key is rebound to a relay that reproduces the
-- cast and then pings. Fully static -- written once out of combat. No source
-- button needed since the cast goes by name, so an Add-By-ID entry with a Key
-- Override works here too.
local function PKArmAlways(e, slotIndex, autoN)
    local k = PKKeyFor(e)
    local cast = PKCastLines(e)
    if not (k and cast) then return false end
    -- Never override a bar key that no longer holds this spell -- see
    -- PKEntryMatchesBar. This is the mode that would otherwise BLOCK the cast.
    if not PKEntryMatchesBar(e) then return false end
    -- ping LAST so a macro's own /stopmacro still suppresses the callout
    local r = PKRelay(slotIndex)
    local full = cast .. "\n" .. PKPingLine(e)
    r:SetAttribute("macrotext", full)

    -- both forms baked here, out of combat; the press gate picks between them
    -- per click. pkEvery = 1 leaves the snippet a no-op.
    r:SetAttribute("pkFull", full)
    r:SetAttribute("pkCastOnly", cast)
    r:SetAttribute("pkEvery", tonumber(e.every) or 1)
    r:SetAttribute("pkPress", 0)

    -- recorded on the auto holder rather than bound here: the toggle key has to
    -- be able to drop and restore these in combat, which only a snippet can do
    local h = PKAutoHolder()
    h:SetAttribute("pkAutoKey" .. autoN, k)
    h:SetAttribute("pkAutoRelay" .. autoN, r:GetName())
    return true
end

-- Key entries: the ping key arms the swap and the snippet binds in combat.
local function PKArmKey(h, e, slotIndex, n)
    local k = PKKeyFor(e)
    if not k then return false end
    -- Hold mode does not block the cast (the bar key only diverts while the
    -- ping key is held), but on the wrong spec it would announce a spell the
    -- player does not have. Same guard.
    if not PKEntryMatchesBar(e) then return false end
    local r = PKRelay(slotIndex)
    r:SetAttribute("macrotext", PKPingLine(e))
    h:SetAttribute("pkKey" .. n, k)
    h:SetAttribute("pkRelay" .. n, r:GetName())
    return true
end

-- "Any spell": every key on your bars pings whatever it holds. Baked from live
-- bar contents, so this is the one path that needs the stale-page guard.
local function PKArmAnySpell(h)
    local btns = PKCollectButtons()
    local seen, n = {}, 0
    for i = 1, #btns do
        if n >= PK_ALL_MAX then break end
        local sid, cmd, kind = PKButtonSubject(btns[i])
        local k = PKKeyForButton(btns[i])
        -- one relay per KEY, not per button: two buttons sharing a key would
        -- otherwise fight over the same binding
        if sid and k and not seen[k] then
            seen[k] = true
            n = n + 1
            -- offset past the picked-list relays: both pools were using 1..12
            local r = PKRelay(PK_MAX + n)
            r:SetAttribute("macrotext", PKPingLine({ id = sid, kind = kind }))
            h:SetAttribute("pkKey" .. n, k)
            h:SetAttribute("pkRelay" .. n, r:GetName())
        end
    end
    return n
end

-- Own-key entries: one dedicated key that PINGS ONLY. No ping key to hold, no
-- bar key involved, and nothing is cast -- this is the "tell the group it is on
-- cooldown, after the fact" case that neither other mode can express.
local function PKArmOwn(e, slotIndex)
    local k = e.ownKey
    if not k or k == "" then return false end
    local r = PKRelay(slotIndex)
    r:SetAttribute("macrotext", PKPingLine(e))
    SetOverrideBindingClick(pkAlwaysOwner, true, k, r:GetName())
    return true
end

PKApply = function()
    -- never write bindings or attributes in combat; re-arm on regen instead
    if InCombatLockdown() then pkDirty = true; return end
    pkDirty = false
    PKEnsureOwners()
    ClearOverrideBindings(pkBindOwner)
    ClearOverrideBindings(pkAlwaysOwner)
    -- every holder resets: a ping key can stop being used entirely when the last
    -- spell on it changes mode, and a stale holder would keep answering
    for _k, h in pairs(pkHolders) do
        h:SetAttribute("pkCount", 0)
        h:SetAttribute("pkGuard", false)
    end
    pkArmed, pkSkipped = 0, 0
    if not (Cfg("pkEnabled") and PKUsable()) then return end

    local barState = PKBarState()
    local globalKey = Cfg("pkKey")
    -- DEFAULT IS "EVERY SPELL". Holding the ping key over any bound spell pings
    -- it; the picked list is for spells that want something DIFFERENT (their own
    -- ping key, auto-ping on cast, or a ping-only key). "Only Selected Spells"
    -- narrows the ping key to the list instead.
    --
    -- These two layers COEXIST -- the old early-return meant turning on any-spell
    -- silently killed every always-mode and own-key entry.
    local onlySel = Cfg("pkOnlySelected") == true
    local perKeyN = {}    -- pingKey -> how many spells are on that holder

    if not onlySel and globalKey and globalKey ~= "" then
        local h = PKHolder(globalKey)
        -- only this layer bakes from live bar contents, so only it needs the
        -- stale-page guard. It covers the whole holder, so a paged bar pauses
        -- that key's per-spell entries too -- conservative, never wrong.
        h:SetAttribute("pkGuard", true)
        local n = PKArmAnySpell(h)
        perKeyN[globalKey] = n
        pkArmed = n
    end

    -- The picked list, each entry by its OWN mode. Runs regardless of the layer
    -- above, and its hold entries are appended AFTER the any-spell ones on the
    -- same holder so the later SetBindingClick wins for that key.
    local list = PKList()
    local slot, autoN = 0, 0
    for i = 1, #list do
        local e = list[i]
        if e and e.id and PKEntryOn(e) and slot < PK_MAX then
            slot = slot + 1
            local mode, ok = PKEntryMode(e), nil
            if mode == "always" then
                autoN = autoN + 1
                ok = PKArmAlways(e, slot, autoN)
                if not ok then autoN = autoN - 1 end
            elseif mode == "own" then
                ok = PKArmOwn(e, slot)
            else
                local pk = PKPingKeyFor(e)
                if pk then
                    local h = PKHolder(pk)
                    local n = (perKeyN[pk] or 0) + 1
                    ok = PKArmKey(h, e, slot, n)
                    if ok then perKeyN[pk] = n end
                end
            end
            if ok then pkArmed = pkArmed + 1 else pkSkipped = pkSkipped + 1 end
        end
    end

    for pk, n in pairs(perKeyN) do
        local h = PKHolder(pk)
        h:SetAttribute("pkCount", n)
        h:SetAttribute("pkBakedState", barState)
        h:SetAttribute("pkLiveState", barState)
        if n > 0 then SetOverrideBindingClick(pkBindOwner, true, pk, h:GetName()) end
    end

    -- hand the always list to the auto holder and let its snippet bind it. The
    -- Hide/Show is the apply trigger (_onshow runs pkAutoApply) -- Lua never
    -- binds these itself, so the toggle key can drop and restore them in combat.
    local ah = PKAutoHolder()
    ah:SetAttribute("pkAutoCount", autoN)
    ah:SetAttribute("pkAutoOn", Cfg("pkAutoOn") ~= false)
    ah:Hide()
    ah:Show()
    local tk = Cfg("pkToggleKey")
    if tk and tk ~= "" and autoN > 0 then
        SetOverrideBindingClick(pkBindOwner, true, tk, ah:GetName())
    end
end

-- ── SELECT MODE ─────────────────────────────────────────────────────────────
-- Click "Select Spells" and every action-bar button grows a clickable overlay:
-- click one to add that spell to the ping list, click again to remove. The
-- overlay is an ordinary frame sitting ON TOP of the (protected) action button,
-- so it eats the mouse click and the spell never fires -- no secure code, and
-- nothing about the real button is touched.
--
-- Picking a spell this way also captures the button's BINDING COMMAND, which is
-- how ElvUI/Bartender users get a working key without typing one: we resolve
-- GetBindingKey(cmd) live instead of guessing from a slot scan.

local pkSel = { on = false, overlays = {}, buttons = {}, banner = nil }
local PKSelRefresh   -- fwd

-- Every action button we can find, UNIONED. This used to return on the first
-- matching probe, which dropped Blizzard's bars wholesale the moment Bartender4
-- was installed -- wrong for anyone running a third-party addon for only some
-- of their bars.
local PK_BTN_NAMES = {
    -- ElvUI: bars 11/12 do not exist
    function(list)
        for _, bar in ipairs({ 1,2,3,4,5,6,7,8,9,10,13,14,15 }) do
            for i = 1, 12 do list[#list + 1] = ("ElvUI_Bar%dButton%d"):format(bar, i) end
        end
    end,
    -- Bartender4 numbers by ABSOLUTE slot: bars 13/14/15 live at 145..180, so a
    -- 1..120 sweep missed three whole bars.
    function(list)
        for i = 1, 180 do list[#list + 1] = "BT4Button" .. i end
    end,
    -- EllesmereUI, also absolute-slot named
    function(list)
        for i = 1, 180 do list[#list + 1] = "EABButton" .. i end
    end,
    -- Blizzard
    function(list)
        local bars = {
            "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
            "MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button",
            "MultiBar6Button", "MultiBar7Button",
        }
        for _b = 1, #bars do
            for i = 1, 12 do list[#list + 1] = bars[_b] .. i end
        end
    end,
}

PKCollectButtons = function()
    local out, seen = {}, {}
    local function take(f)
        if type(f) ~= "table" or seen[f] or not f.GetObjectType then return end
        -- Every bar addon marks the Blizzard buttons it replaced with
        -- statehidden. Those frames keep a STALE .action, so without this filter
        -- they produce catalog entries for the wrong spell on a real key --
        -- the nastiest phantom available, since GetBindingKey("ACTIONBUTTON1")
        -- still answers under Bartender4. LAB never sets it on its own buttons.
        if f.GetAttribute and f:GetAttribute("statehidden") then return end
        seen[f] = true
        out[#out + 1] = f
    end

    -- 1. LibActionButton's OWN registry: covers every LAB-based bar, present and
    --    future, with no name guessing. Bartender4 and ElvUI ship separate
    --    copies under different major strings, so enumerate rather than hardcode.
    if LibStub and type(LibStub.libs) == "table" then
        for major, lib in pairs(LibStub.libs) do
            if type(major) == "string" and major:find("^LibActionButton%-1%.0")
               and type(lib) == "table" and type(lib.GetAllButtons) == "function" then
                for b in pairs(lib:GetAllButtons()) do take(b) end
            end
        end
    end
    -- 2. known names, for bars that are not LAB-based (Blizzard, EllesmereUI)
    local names = {}
    for i = 1, #PK_BTN_NAMES do PK_BTN_NAMES[i](names) end
    for i = 1, #names do take(_G[names[i]]) end

    -- the LAB registry is a SET, so its iteration order changes between reloads.
    -- Sort by name or the catalog's first-come-wins dedupe is nondeterministic.
    table.sort(out, function(a, b)
        local an = (a.GetName and a:GetName()) or ""
        local bn = (b.GetName and b:GetName()) or ""
        return an < bn
    end)
    return out
end

-- What a bar button is holding, as a PING SUBJECT. Blizzard ships /pingspell
-- AND /pingitem, so trinkets, potions and item macros are pingable too -- a
-- macro resolves to whichever it actually casts (GetMacroSpell first, then
-- GetMacroItem), which is why a "/use Healthstone" macro now shows up in the
-- picker where the old spell-only lookup skipped it.
-- Returns: id, bindingCommand, kind ("spell"|"item"), buttonName
PKButtonSubject = function(btn)
    local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
    if type(slot) ~= "number" or not HasAction(slot) then return nil end
    local aType, id = GetActionInfo(slot)
    local kind, sid
    -- Plain item and spell slots are unambiguous.
    if aType == "spell" then
        kind, sid = "spell", id
    elseif aType == "item" then
        kind, sid = "item", id
    elseif aType == "macro" then
        -- Macros need a resolver. C_ActionBar.GetSpell is the DOCUMENTED one
        -- and sees straight through a macro to the spell the slot will cast --
        -- which matters in 12.1, where GetMacroSpell is undocumented and
        -- GetMacroItem has no references left in Blizzard's code at all. The
        -- legacy globals stay as a fallback for item macros only, guarded by an
        -- existence check so a removed global degrades to "skip" not an error.
        if C_ActionBar and C_ActionBar.GetSpell then
            local s = C_ActionBar.GetSpell(slot)
            if type(s) == "number" and s > 0 then kind, sid = "spell", s end
        end
        if not sid and GetMacroSpell then
            local ms = GetMacroSpell(id)
            if ms then kind, sid = "spell", ms end
        end
        if not sid and GetMacroItem and GetItemInfoInstant then
            local _mn, mlink = GetMacroItem(id)
            local iid = mlink and GetItemInfoInstant(mlink)
            if iid then kind, sid = "item", iid end
        end
    end
    -- last resort: the slot knows whether it is an item even when the type did
    -- not tell us (item macros)
    if not sid and C_ActionBar and C_ActionBar.GetSpell then
        local s = C_ActionBar.GetSpell(slot)
        if type(s) == "number" and s > 0 then kind, sid = "spell", s end
    end
    if not sid then return nil end
    -- the command that actually resolves right now (falls back to the first
    -- candidate when the button is simply unbound) -- see PKKeyForButton
    local _k, cmd = PKKeyForButton(btn)
    return sid, cmd, kind, btn.GetName and btn:GetName() or nil
end

-- Which half of an override pair is live RIGHT NOW, from either half.
-- Normalise to the base (stable identity), then resolve forward (current
-- reality). A stored id is whatever the bar happened to show when it was
-- captured, so it can be either one.
PKLiveSpellID = function(id)
    if type(id) ~= "number" then return id end
    local sid = id
    if C_Spell and C_Spell.GetBaseSpell then
        local b = C_Spell.GetBaseSpell(sid)
        if type(b) == "number" and b > 0 then sid = b end
    end
    if C_Spell and C_Spell.GetOverrideSpell then
        local o = C_Spell.GetOverrideSpell(sid)
        if type(o) == "number" and o > 0 then sid = o end
    end
    return sid
end

-- display name/icon for a tracked entry, spell or item
PKSubjectInfo = function(entry)
    if entry.kind == "item" then
        local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(entry.id)
        local ic = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(entry.id)
        return nm or ("Item " .. tostring(entry.id)), ic or 134400
    end
    -- show the spell the key ACTUALLY casts today, not the one it cast when
    -- this entry was added
    local live = PKLiveSpellID(entry.id)
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(live)
    return (info and info.name) or ("Spell " .. tostring(entry.id)), (info and info.iconID) or 134400
end

-- The slash line that pings this entry.
--
-- Unlike /cast, /pingspell takes a literal spell ID -- the game will not resolve
-- an override for us -- so we have to land on the right one ourselves.
--
-- Resolving FORWARD from the stored id is not enough. An entry captured while a
-- talent override was up stores the OVERRIDE (Ascendance); dropping the talent
-- leaves GetOverrideSpell(Ascendance) with nothing to say, so it kept pinging
-- Ascendance while the key had gone back to casting Doom Winds.
--
-- So normalise to the BASE first, then resolve forward from there. Base is the
-- stable identity of the pair, and forward-resolution names whichever half is
-- live right now -- correct in both directions.
PKPingLine = function(entry)
    if entry.kind == "item" then return "/pingitem " .. entry.id end
    return "/pingspell " .. PKLiveSpellID(entry.id)
end

-- ── CATALOG ────────────────────────────────────────────────────────────────
-- Everything currently sitting on your action bars, as a browsable list. This is
-- the alternative to the on-bars overlay picker: same subjects, same capture
-- (id/kind/cmd/btn), but readable at a glance in the options panel and without
-- leaving it. Deliberately scanned from the BARS, not the spellbook -- a ping key
-- needs a keybind, and only bar buttons have one.
--
-- Rebuilt on demand (options panel open / Rescan), never on a timer: bar contents
-- change rarely and a scan walks up to 120 frames.
local pkCatalog, pkCatalogBuilt = {}, false

local function PKBuildCatalog()
    wipe(pkCatalog)
    local btns = PKCollectButtons()
    local seen = {}
    for i = 1, #btns do
        local btn = btns[i]
        local id, cmd, kind, bname = PKButtonSubject(btn)
        if id and not seen[id] then
            seen[id] = true
            local e = { id = id, kind = kind or "spell", cmd = cmd, btn = bname }
            local nm, icon = PKSubjectInfo(e)
            e.name, e.icon = nm, icon
            e.key = PKKeyForButton(btn)
            pkCatalog[#pkCatalog + 1] = e
        elseif id and seen[id] then
            -- same subject on two bars: keep whichever copy actually has a key
            for j = 1, #pkCatalog do
                local c = pkCatalog[j]
                if c.id == id and not c.key then
                    local k = PKKeyForButton(btn)
                    if k then c.key, c.cmd, c.btn = k, cmd, bname end
                    break
                end
            end
        end
    end
    -- Anything TRACKED that is not on a bar (added by spell ID, or dragged off
    -- the bars since) is appended so the grid is the complete picture. Without
    -- this such an entry would be tracked but invisible and uneditable, because
    -- the grid is the only way into the editor.
    local list = PKList()
    for i = 1, #list do
        local t = list[i]
        if t and t.id and not seen[t.id] then
            seen[t.id] = true
            local e = { id = t.id, kind = t.kind or "spell", cmd = t.cmd, btn = t.btn, offBar = true }
            local nm, icon = PKSubjectInfo(e)
            e.name, e.icon = nm, icon
            e.key = (t.btn and PKKeyForButton(_G[t.btn]))
                    or (t.cmd and GetBindingKey(t.cmd)) or t.ownKey or nil
            pkCatalog[#pkCatalog + 1] = e
        end
    end
    -- keybound first (those are the ones a ping key can actually reach), then A-Z
    table.sort(pkCatalog, function(a, b)
        local ak, bk = a.key ~= nil, b.key ~= nil
        if ak ~= bk then return ak end
        return (a.name or "") < (b.name or "")
    end)
    pkCatalogBuilt = true
    return #pkCatalog
end

local function PKCatalog()
    if not pkCatalogBuilt then PKBuildCatalog() end
    return pkCatalog
end

local function PKCatalogDirty() pkCatalogBuilt = false end

-- ── catalog selection ───────────────────────────────────────────────────────
-- Which catalog icon the editor is currently showing. Selection is by SUBJECT
-- ID, not list index: the tracked list reorders on removal, and an index would
-- silently point at a different spell afterwards.
local pkSelID

local function PKTracked(id)
    if not id then return nil end
    local list = PKList()
    for i = 1, #list do
        if list[i].id == id then return list[i] end
    end
    return nil
end

local function PKSelect(id) pkSelID = id end
local function PKSelectedID() return pkSelID end

local function PKSelected()
    if not pkSelID then return nil end
    local cat = PKCatalog()
    for i = 1, #cat do
        if cat[i].id == pkSelID then return cat[i] end
    end
    -- selected something that has since left the bars: fall back to the tracked
    -- entry so the editor can still remove it
    local t = PKTracked(pkSelID)
    if t then
        local nm, icon = PKSubjectInfo(t)
        return { id = t.id, kind = t.kind, cmd = t.cmd, btn = t.btn, name = nm, icon = icon }
    end
    return nil
end

-- Enable creates the entry the first time, and thereafter only flips the flag --
-- so a spell toggled off and back on keeps its mode and key override.
local function PKSetSelectedEnabled(on)
    local sel = PKSelected()
    if not sel then return end
    local t = PKTracked(sel.id)
    if on then
        if not t then
            local list = PKList()
            if #list >= PK_MAX then
                print("|cff33ff99ArcUI Pings|r: ping-key list is full (" .. PK_MAX .. " entries).")
                return
            end
            list[#list + 1] = { id = sel.id, kind = sel.kind, cmd = sel.cmd, btn = sel.btn }
        else
            t.enabled = nil
        end
    elseif t then
        t.enabled = false
    end
    DB().pkSpells = PKList()
    PKApply()
end

local function PKRemoveSelected()
    local sel = PKSelected()
    if not sel then return end
    local list = PKList()
    for i = #list, 1, -1 do
        if list[i].id == sel.id then table.remove(list, i) end
    end
    DB().pkSpells = PKList()
    -- an off-bar entry only exists in the catalog BECAUSE it was tracked, so
    -- removing it has to drop it from the grid too
    if sel.offBar then
        PKCatalogDirty()
        pkSelID = nil
    end
    PKApply()
end

-- search filter shared by the options grid
local pkCatSearch = ""
local PK_CAT_MAX  = 60   -- grid cap; the count line says when it truncates

local pkCatView = "all"   -- "all" | "on" (pinging) | "off" (not pinging)
local function PKSetCatView(v) pkCatView = v or "all" end
local function PKGetCatView() return pkCatView end

local function PKCatalogFiltered()
    local all = PKCatalog()
    local q = (pkCatSearch ~= "") and pkCatSearch:lower() or nil
    if not q and pkCatView == "all" then return all end
    local out = {}
    for i = 1, #all do
        local e = all[i]
        local ok = true
        if q then
            local n = e.name
            ok = n and n:lower():find(q, 1, true) ~= nil
        end
        if ok and pkCatView ~= "all" then
            local t = PKTracked(e.id)
            local pinging = (t ~= nil) and PKEntryOn(t)
            ok = (pkCatView == "on") == pinging
        end
        if ok then out[#out + 1] = e end
    end
    return out
end

local function PKIndexOf(spellID)
    local list = PKList()
    for i = 1, #list do
        if list[i].id == spellID then return i end
    end
    return nil
end

local function PKToggleSpell(spellID, cmd, kind, bname)
    local i = PKIndexOf(spellID)
    local list = PKList()
    if i then
        table.remove(list, i)
    else
        if #list >= PK_MAX then
            print("|cff33ff99ArcUI Pings|r: ping-key list is full (" .. PK_MAX .. " entries).")
            return
        end
        -- btn is kept for Always mode: its relay has to /click the REAL button
        -- so the cast still respects paging, overrides and macro conditionals
        list[#list + 1] = { id = spellID, cmd = cmd, kind = kind or "spell", btn = bname }
    end
    if PKApply then PKApply() end
    if PKSelRefresh then PKSelRefresh() end
end

local function PKOverlayFor(btn)
    local o = pkSel.overlays[btn]
    if o then return o end
    o = CreateFrame("Button", nil, btn)
    o:SetAllPoints(btn)
    o:SetFrameStrata("FULLSCREEN")
    o:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    o.tint = o:CreateTexture(nil, "OVERLAY")
    o.tint:SetAllPoints()
    o.tint:SetColorTexture(0.247, 0.788, 0.949, 0.30)
    o.tint:Hide()
    o.ring = o:CreateTexture(nil, "OVERLAY", nil, 1)
    o.ring:SetPoint("TOPLEFT", -2, 2)
    o.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    o.ring:SetColorTexture(0.247, 0.788, 0.949, 0.55)
    o.ring:Hide()
    o.check = o:CreateTexture(nil, "OVERLAY", nil, 2)
    o.check:SetSize(16, 16)
    o.check:SetPoint("TOPRIGHT", -1, -1)
    o.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    o.check:Hide()
    -- dim buttons holding nothing pingable so the eye goes to the real choices
    o.dim = o:CreateTexture(nil, "BACKGROUND")
    o.dim:SetAllPoints()
    o.dim:SetColorTexture(0, 0, 0, 0.55)
    o.dim:Hide()
    o:SetScript("OnClick", function()
        local sid, cmd, kind, bname = PKButtonSubject(btn)
        if sid then PKToggleSpell(sid, cmd, kind, bname) end
    end)
    o:SetScript("OnEnter", function(self)
        local sid, _cmd, kind = PKButtonSubject(btn)
        if not sid then return end
        self.ring:SetColorTexture(1, 1, 1, 0.75)
        self.ring:Show()
        local nm = PKSubjectInfo({ id = sid, kind = kind })
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(nm, 1, 1, 1)
        GameTooltip:AddLine(PKIndexOf(sid) and "Click to stop pinging this"
            or "Click to ping this", 0.6, 0.85, 1)
        GameTooltip:Show()
    end)
    o:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if PKSelRefresh then PKSelRefresh() end
    end)
    o:Hide()
    pkSel.overlays[btn] = o
    return o
end

PKSelRefresh = function()
    if not pkSel.on then return end
    for i = 1, #pkSel.buttons do
        local btn = pkSel.buttons[i]
        local o = pkSel.overlays[btn]
        if o then
            local sid = PKButtonSubject(btn)
            local picked = sid and PKIndexOf(sid)
            o.dim:SetShown(not sid)
            o.tint:SetShown(picked and true or false)
            o.check:SetShown(picked and true or false)
            o.ring:SetColorTexture(0.247, 0.788, 0.949, 0.55)
            o.ring:SetShown(sid and true or false)
        end
    end
    if pkSel.banner and pkSel.banner.count then
        local n = #PKList()
        pkSel.banner.count:SetText(("|cff33ff99%d|r of %d selected"):format(n, PK_MAX))
    end
    -- the options panel keeps its list in sync while picking (set by the panel)
    if pkSel.notify then pkSel.notify() end
end

local PKExitSelect  -- fwd

local function PKBanner()
    if pkSel.banner then return pkSel.banner end
    local b = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    b:SetSize(420, 66)
    b:SetPoint("TOP", UIParent, "TOP", 0, -120)
    b:SetFrameStrata("FULLSCREEN_DIALOG")
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b:SetBackdropColor(0.043, 0.059, 0.102, 0.96)
    b:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
    local t = b:CreateFontString(nil, "OVERLAY")
    t:SetFont(STANDARD_TEXT_FONT, 13, "")
    t:SetPoint("TOP", 0, -10)
    t:SetText("|cff3fc9f2Pick the spells you want to ping|r")
    local sub = b:CreateFontString(nil, "OVERLAY")
    sub:SetFont(STANDARD_TEXT_FONT, 11, "")
    sub:SetPoint("TOP", t, "BOTTOM", 0, -4)
    sub:SetTextColor(0.51, 0.60, 0.71)
    sub:SetText("click a spell on your bars to add it, click again to remove")
    b.count = b:CreateFontString(nil, "OVERLAY")
    b.count:SetFont(STANDARD_TEXT_FONT, 11, "")
    b.count:SetPoint("BOTTOMLEFT", 12, 8)
    local done = CreateFrame("Button", nil, b, "BackdropTemplate")
    done:SetSize(80, 20)
    done:SetPoint("BOTTOMRIGHT", -10, 8)
    done:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    done:SetBackdropColor(0.09, 0.13, 0.20, 1)
    done:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
    local dfs = done:CreateFontString(nil, "OVERLAY")
    dfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    dfs:SetPoint("CENTER")
    dfs:SetText("Done")
    done:SetScript("OnClick", function() PKExitSelect() end)
    b:Hide()
    pkSel.banner = b
    return b
end

local function PKEnterSelect()
    if pkSel.on then PKExitSelect() return end
    pkSel.on = true
    pkSel.buttons = PKCollectButtons()
    if #pkSel.buttons == 0 then
        pkSel.on = false
        print("|cff33ff99ArcUI Pings|r: no action bar buttons found to pick from.")
        return
    end
    for i = 1, #pkSel.buttons do
        local o = PKOverlayFor(pkSel.buttons[i])
        o:EnableMouse(true)
        o:Show()
    end
    PKBanner():Show()
    PKSelRefresh()
end

PKExitSelect = function()
    pkSel.on = false
    for _btn, o in pairs(pkSel.overlays) do
        o:EnableMouse(false)
        o:Hide()
    end
    if pkSel.banner then pkSel.banner:Hide() end
    GameTooltip:Hide()
    -- hand the user back to where they came from (set by the options panel)
    if pkSel.onExit then pkSel.onExit() end
end

Pings.PKApply    = function() PKApply() end
Pings.PKList     = PKList
Pings.PKUsable   = PKUsable
Pings.PKMax      = PK_MAX

-- ── PING KEYS DEBUG ─────────────────────────────────────────────────────────
-- Dumps what each relay ACTUALLY holds. The cast half of an Always entry has
-- several places it can silently fall through (slot lookup, action type, macro
-- body read), and all of them look identical in game: the ping fires, nothing
-- casts. This shows which step produced the macrotext that is really loaded.
local pkDbgWin
local function PKDebugWindow(text)
    if not pkDbgWin then
        local f = CreateFrame("Frame", "ArcUIPKDebug", UIParent, "BackdropTemplate")
        f:SetSize(620, 460)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        f:SetBackdropColor(0.043, 0.059, 0.102, 0.97)
        f:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
        local t = f:CreateFontString(nil, "OVERLAY")
        t:SetFont(STANDARD_TEXT_FONT, 13, "")
        t:SetPoint("TOPLEFT", 12, -10)
        t:SetText("|cff3fc9f2Ping Keys|r  — relay dump (Ctrl+A, Ctrl+C)")
        local close = CreateFrame("Button", nil, f)
        close:SetSize(24, 24); close:SetPoint("TOPRIGHT", -6, -6)
        local cx = close:CreateFontString(nil, "OVERLAY")
        cx:SetFont(STANDARD_TEXT_FONT, 14, ""); cx:SetPoint("CENTER"); cx:SetText("x")
        close:SetScript("OnClick", function() f:Hide() end)
        local sf = CreateFrame("ScrollFrame", "ArcUIPKDebugScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -34)
        sf:SetPoint("BOTTOMRIGHT", -30, 12)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject("GameFontHighlightSmall")
        eb:SetWidth(560)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        sf:SetScrollChild(eb)
        f.eb = eb
        pkDbgWin = f
    end
    pkDbgWin.eb:SetText(text)
    pkDbgWin.eb:HighlightText()
    pkDbgWin:Show()
end

local function PKDebugDump()
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("enabled=" .. tostring(Cfg("pkEnabled"))
        .. "  onlySelected=" .. tostring(Cfg("pkOnlySelected"))
        .. "  pingKey=" .. tostring(Cfg("pkKey"))
        .. "  combat=" .. tostring(InCombatLockdown())
        .. "  autoPing=" .. tostring(PKAutoOn()) .. " toggleKey=" .. tostring(Cfg("pkToggleKey")))
    do
        local t = OvTable(ActiveScope(), false)
        local n = 0
        if t then for _k in pairs(t) do n = n + 1 end end
        add(("editScope=%s  overridesHere=%d  spellList=this character (%d entries)")
            :format(ActiveScope(), n, #PKList()))
        -- WHICH STORE HOLDS WHAT. If a position you set at character scope also
        -- shows up on the account line, something wrote through the resolver --
        -- this makes that visible instead of guessable.
        local function posOf(tbl)
            local pp = tbl and tbl.pos
            if not pp then return "none" end
            return ("x=%s y=%s top=%s bottom=%s"):format(
                tostring(pp[1]), tostring(pp[2]), tostring(pp.top), tostring(pp.bottom))
        end
        add("  pos account : " .. posOf(GlobalDB()))
        add("  pos char    : " .. posOf(OvTable(SCOPE_CHAR, false)))
        add("  pos spec    : " .. posOf(OvTable(SCOPE_SPEC, false)))
        add("  pos charDB  : " .. posOf(DB()) .. "   (legacy, should be unused)")
        local ps = PosStore()
        add("  resolving from: " .. (ps == GlobalDB() and "account"
            or ps == OvTable(SCOPE_SPEC, false) and "spec"
            or ps == OvTable(SCOPE_CHAR, false) and "char" or "charDB(legacy)"))
    end
    add("GetMacroInfo=" .. tostring(GetMacroInfo ~= nil)
        .. "  C_ActionBar.GetSpell=" .. tostring(C_ActionBar and C_ActionBar.GetSpell ~= nil))
    -- HOLD-MODE PROOF: which ping keys have a holder, how many spells are on
    -- each, and what the key currently resolves to. NOTE boundTo shows the
    -- NORMAL binding -- it is how we caught key 7 already belonging to
    -- EXTRAACTIONBUTTON1 while our override was set non-priority and losing.
    add("-- hold-mode holders --")
    local anyHolder = false
    for pk, h in pairs(pkHolders) do
        anyHolder = true
        add(("  pingKey=%s holder=%s pkCount=%s guard=%s boundTo=%s")
            :format(tostring(pk), tostring(h:GetName()),
                tostring(h:GetAttribute("pkCount")), tostring(h:GetAttribute("pkGuard")),
                tostring(GetBindingAction and GetBindingAction(pk) or "?")))
        local n = h:GetAttribute("pkCount") or 0
        for i = 1, n do
            add(("    [%d] key=%s relay=%s macrotext=[%s]"):format(i,
                tostring(h:GetAttribute("pkKey" .. i)),
                tostring(h:GetAttribute("pkRelay" .. i)),
                tostring(_G[h:GetAttribute("pkRelay" .. i) or ""] and
                    _G[h:GetAttribute("pkRelay" .. i)]:GetAttribute("macrotext"))))
        end
    end
    if not anyHolder then add("  (no hold-mode holders created)") end
    add("")
    local list = PKList()
    if #list == 0 then add("(no spells selected)") end
    for i = 1, #list do
        local e = list[i]
        local nm = PKSubjectInfo(e)
        add(("[%d] %s  id=%s kind=%s mode=%s"):format(i, tostring(nm), tostring(e.id),
            tostring(e.kind), PKEntryMode(e)))
        add("     btn=" .. tostring(e.btn) .. "  exists=" .. tostring(e.btn and _G[e.btn] ~= nil))
        add("     cmd=" .. tostring(e.cmd) .. "  pingKey=" .. tostring(e.pingKey) .. " ownKey=" .. tostring(e.ownKey)
            .. "  resolvedKey=" .. tostring(PKKeyFor(e)))
        local btn = e.btn and _G[e.btn]
        if btn then
            local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
            add("     slot=" .. tostring(slot) .. "  hasAction=" ..
                tostring(type(slot) == "number" and HasAction(slot) or false))
            if type(slot) == "number" and HasAction(slot) then
                local aType, aid, sub = GetActionInfo(slot)
                add("     GetActionInfo -> type=" .. tostring(aType)
                    .. " id=" .. tostring(aid) .. " sub=" .. tostring(sub))
                if aType == "macro" then
                    local mname = GetActionText and GetActionText(slot)
                    local idx = PKMacroIndexForSlot(slot)
                    add("     macroName=" .. tostring(mname) .. "  macroIndex=" .. tostring(idx))
                    -- list every macro sharing that name: a collision between an
                    -- account and a character macro is what made this pick wrong
                    if mname and GetNumMacros and GetMacroInfo then
                        local acct, char = GetNumMacros()
                        local cands = {}
                        local function scan(from, to)
                            for mi = from, to do
                                if GetMacroInfo(mi) == mname then
                                    cands[#cands + 1] = mi .. "(spell=" ..
                                        tostring(GetMacroSpell and GetMacroSpell(mi)) .. ")"
                                end
                            end
                        end
                        scan(1, acct or 0)
                        scan(PK_MACRO_BASE + 1, PK_MACRO_BASE + (char or 0))
                        add("     sameName=[" .. table.concat(cands, " ") .. "]  wantSpell=" .. tostring(aid))
                    end
                    if idx and GetMacroInfo then
                        local mn, _mt, body = GetMacroInfo(idx)
                        add("     GetMacroInfo(" .. tostring(idx) .. ") -> name=" .. tostring(mn)
                            .. " bodyLen=" .. tostring(type(body) == "string" and #body or "n/a"))
                        if type(body) == "string" then add("     body: [" .. body .. "]") end
                    end
                end
            end
        end
        local r = pkRelays[i]
        add("     relay=" .. tostring(r and r:GetName())
            .. "  type=" .. tostring(r and r:GetAttribute("type")))
        add("     macrotext: [" .. tostring(r and r:GetAttribute("macrotext")) .. "]")
        if r and r:GetAttribute("pkFull") then
            -- press gate: pkPress is written by the snippet, so this is also the
            -- proof that the pre-click ran at all
            -- pressCounter is written ONLY by the snippet, so a value that
            -- moves as you press is the proof the pre-click gate really ran
            add(("     gate: every=%s  pressCounter=%s"):format(
                tostring(r:GetAttribute("pkEvery")), tostring(r:GetAttribute("pkPress"))))
        end
        if r and r:GetAttribute("pkFull") then
            add("     castOnly: [" .. tostring(r:GetAttribute("pkCastOnly")) .. "]")
        end
        add("")
    end
    PKDebugWindow(table.concat(out, "\n"))
end
_G.ArcUI_PingDebug = PKDebugDump

local pkRebindQueued = false
local pkEv = CreateFrame("Frame")
pkEv:RegisterEvent("PLAYER_REGEN_ENABLED")
pkEv:RegisterEvent("UPDATE_BINDINGS")
pkEv:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
pkEv:RegisterEvent("PLAYER_ENTERING_WORLD")
pkEv:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
pkEv:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
-- Talent-driven spell overrides. The CAST line survives these on its own (it
-- casts the base spell), but the PING line is resolved forward at bake time, so
-- without these it would keep naming the spell you used to have. Deliberately
-- NOT SPELLS_CHANGED, which fires constantly during loading for no gain.
pkEv:RegisterEvent("TRAIT_CONFIG_UPDATED")
pkEv:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
pkEv:SetScript("OnEvent", function(_, ev)
    -- The toggle key can flip Auto-Ping mid-fight, which only the holder knows
    -- about. Write that back to the DB BEFORE any re-apply, or the next PKApply
    -- would push the stale saved value over the user's in-combat choice.
    if ev == "PLAYER_REGEN_ENABLED" and pkAutoHolder then
        local live = pkAutoHolder:GetAttribute("pkAutoOn") and true or false
        if live ~= (Cfg("pkAutoOn") ~= false) then DB().pkAutoOn = live end
    end
    -- the catalog mirrors the bars, so anything that moves a spell or a binding
    -- stales it; mark rather than rescan (a scan walks up to 120 frames and the
    -- panel may not even be open)
    if ev == "UPDATE_BINDINGS" or ev == "ACTIONBAR_SLOT_CHANGED"
        or ev == "ACTIONBAR_PAGE_CHANGED" or ev == "PLAYER_ENTERING_WORLD"
        or ev == "TRAIT_CONFIG_UPDATED" or ev == "PLAYER_SPECIALIZATION_CHANGED" then
        PKCatalogDirty()
    end
    -- auto-resolved keys move when the user rebinds or drags a spell to another
    -- slot; re-arm on those, and flush anything deferred out of combat
    if ev == "PLAYER_REGEN_ENABLED" and not pkDirty then return end
    if not (Cfg("pkEnabled") or pkDirty) then return end
    -- UPDATE_BINDINGS: bar addons re-apply their OWN override bindings on this
    -- same event, and handler order between addons is undefined. Ours are
    -- priority overrides and theirs are not, but priority turned out to be
    -- recency here, not strict precedence: hold mode worked (it binds inside a
    -- snippet at key-down, after everyone) while always mode lost the key
    -- whenever the bar addon happened to run second. Deferring one frame puts
    -- us last deterministically.
    if ev == "UPDATE_BINDINGS" then
        if not pkRebindQueued then
            pkRebindQueued = true
            C_Timer.After(0, function()
                pkRebindQueued = false
                if Cfg("pkEnabled") or pkDirty then PKApply() end
            end)
        end
        return
    end
    PKApply()
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PINGABLE ARC ICONS (recipe: PingableType_CooldownViewerItemMixin pattern)
-- ═══════════════════════════════════════════════════════════════════════════

local pingableCount = 0

-- ── "DON'T PING THIS ICON" ──────────────────────────────────────────────────
-- Hovering a pingable icon HIJACKS the ping: instead of pinging the world you
-- announce whatever is under the cursor. The opt-out is the `ping-receiver`
-- ATTRIBUTE, never GetIsPingable.
--
-- GetIsPingable() = false is the wrong lever and does the opposite of what it
-- reads like: PingManager treats "frame found but not pingable" as BLOCKING UI
-- and fails the ping outright rather than falling through to the world
-- (Blizzard_PingManager.lua, the frameFound branch). Only a MISSING attribute
-- makes a frame invisible to C_PingSecure.GetTargetPingReceiver. Blizzard use
-- exactly this to let pings pass through empty action buttons
-- (PingableType_ActionButtonMixin:UpdatePingAttributes).
--
-- Safe on Blizzard's own CDM frames, verified in source and in game:
--   * the attribute is set DECLARATIVELY in XML (PingReceiverAttributeTemplate
--     via CooldownViewerEssential/UtilityItemTemplate), and
--     PingableTypeMixin:UpdatePingAttributes is an empty stub that the CDM mixin
--     does NOT override -- so nothing ever re-asserts it and a one-time clear
--     sticks. No refresh fight.
--   * CDM has no OnAttributeChanged handler, so nothing reacts to the write.
--   * CDM item frames report IsProtected() == false, so the write is legal in
--     combat too.
-- It does NOT survive a reload (XML re-applies it), which is fine: the sweep
-- below re-runs on login and on every rebind.
--
-- Note click-through does NOT help here: CDM icons report mouse disabled and
-- are still ping receivers, so the hit test does not consult mouse state.
local function SetPingReceiver(frame, on)
    if not (frame and frame.SetAttribute) then return end
    if on then
        frame:SetAttribute("ping-receiver", true)
    else
        frame:ClearAttribute("ping-receiver")
    end
end

-- Should this icon accept pings? Per-icon wins, then its group, then the global
-- default. Every layer stores the OPT-OUT (noPing), so an absent value means
-- "pingable" and existing setups are unchanged.
function Pings.IconAcceptsPings(cdID)
    if not cdID then return true end
    local CE = ns.CDMEnhance
    -- 1. THIS icon, read SPARSE. The merged read cannot tell "set on this icon"
    --    apart from "inherited from the global defaults", and using it here let
    --    a global default shadow the group layer entirely.
    local raw = CE and CE.GetRawIconSettings and CE.GetRawIconSettings(cdID)
    if raw and raw.noPing ~= nil then return raw.noPing ~= true end

    -- 2. its group
    if ns.CDMGroups and ns.CDMGroups.GetGroupNameForIcon then
        local gname = ns.CDMGroups.GetGroupNameForIcon(cdID)
        local g = gname and ns.CDMGroups.groups and ns.CDMGroups.groups[gname]
        if g and g.noPing ~= nil then return g.noPing ~= true end
    end

    -- 3. the global default (the merged read folds defaults + global in)
    local S = CE and CE.GetIconSettings and CE.GetIconSettings(cdID)
    if S and S.noPing ~= nil then return S.noPing ~= true end

    local db = ns.CDMShared and ns.CDMShared.GetCDMGroupsDB and ns.CDMShared.GetCDMGroupsDB()
    if db and db.noPingAll ~= nil then return db.noPingAll ~= true end
    return true
end

local function MakePingable(frame, cdID, getTargetInfo)
    if not (frame and getTargetInfo and PingableTypeMixin) then return end
    if not frame._arcPingable then
        frame._arcPingable = true
        Mixin(frame, PingableTypeMixin)
        -- always TRUE: see the note above -- false would make this a ping
        -- blocker rather than letting the ping through to the world
        frame.GetIsPingable = function() return true end
        frame.GetAllowRadialWheel = function() return false end
        frame.GetTargetInfo = getTargetInfo
    end
    local accepts = Pings.IconAcceptsPings(cdID)
    SetPingReceiver(frame, accepts)
    if accepts then pingableCount = pingableCount + 1 end
end

-- Sweep every ArcUI-created icon: SPELL + TIMER icons ping their spell
-- (override-resolved), ITEM icons ping their itemID (GetTargetInfo takes
-- itemID -- the PingableType_ActionButtonMixin item pattern), TRINKET icons
-- live-resolve the equipped item at ping time (swaps stay correct). Totem
-- icons are skipped (a slot has no stable ping subject). Blizzard CDM
-- frames are never touched: Essential/Utility are natively pingable and
-- attribute writes on Blizzard frames are not worth the taint surface.
-- Blizzard's CDM icons are pingable NATIVELY (Essential and Utility inherit
-- PingReceiverAttributeTemplate; the Buff viewers do not). We never make one
-- pingable -- it already is -- we only ever honour an opt-out by clearing the
-- attribute, and put it back when the opt-out is removed.
--
-- READS ONLY apart from that attribute: no CooldownViewer METHOD calls. Calling
-- a CDM object method from addon code runs Blizzard's Lua on our tainted stack
-- and can bake taint into shared CDM state, which is what bricks CDM in M+.
-- Enumerate through ArcUI's OWN registry, keyed by cooldownID and holding the
-- frame wherever it currently lives.
--
-- Walking `viewer:GetChildren()` is WRONG here and is why the toggle only took
-- effect after a reload: ArcUI REPARENTS CDM icons into its own group and free
-- containers, so once groups are built the viewers no longer own them. At login
-- the sweep ran before reparenting and appeared to work; every later call found
-- nothing to update. (Same trap the CDM hide-icon bug hit -- never sweep CDM by
-- viewer children.)
--
-- Reads only, plus the attribute write. No CooldownViewer method calls.
local function RefreshCDMPingable()
    local CE = ns.CDMEnhance
    local frames = CE and CE.GetEnhancedFrames and CE.GetEnhancedFrames()
    if type(frames) ~= "table" then return end
    for cdID, data in pairs(frames) do
        local f = type(data) == "table" and data.frame or data
        if cdID and type(f) == "table" and f.SetAttribute and f.GetAttribute then
            -- Remember whether Blizzard made THIS frame a receiver, the first
            -- time we ever touch it. Essential/Utility inherit the attribute
            -- from XML; the Buff viewers do NOT. Without this we would ADD the
            -- attribute to buff icons on the way back and make them pingable
            -- when Blizzard never intended them to be.
            if f._arcPingNative == nil then
                f._arcPingNative = (f:GetAttribute("ping-receiver") == true)
            end
            if f._arcPingNative then
                SetPingReceiver(f, Pings.IconAcceptsPings(cdID))
            end
        end
    end
end

-- CDM recreates and REBINDS its item frames (spec change, talent change, a CDM
-- rebuild), and a rebound frame carries a different cooldownID -- so the
-- opt-out has to be re-resolved for it. FrameController is the single authority
-- for that event; subscribing is idempotent.
local pingRebindHooked = false
local function HookPingRebind()
    if pingRebindHooked then return end
    local FC = ns.FrameController
    if not (FC and FC.OnFrameRebind) then return end
    pingRebindHooked = true
    FC.OnFrameRebind(function(frame, _oldCdID, newCdID)
        -- targeted: only the frame that just rebound. No CDM API calls, no
        -- secret reads -- an attribute write and a settings lookup.
        if frame and frame.SetAttribute and newCdID and frame._arcPingNative then
            SetPingReceiver(frame, Pings.IconAcceptsPings(newCdID))
        end
    end)
end

function Pings.RefreshPingable()
    HookPingRebind()
    pingableCount = 0
    -- NOT gated on the standalone: only ArcUI can make ArcUI icons pingable
    if not HAS_ACTION_PINGS then return end
    RefreshCDMPingable()
    local AA = ns.ArcAuras
    if not (AA and AA.frames and AA.ParseArcID) then return end
    for arcID, frame in pairs(AA.frames) do
        local kind, id = AA.ParseArcID(arcID)
        if frame and id then
            if kind == "spell" or kind == "timer" or kind == "aura" then
                MakePingable(frame, arcID, function()
                    -- cooldown pings follow the live override form
                    local sid = id
                    if C_Spell.GetOverrideSpell then
                        local o = C_Spell.GetOverrideSpell(id)
                        if type(o) == "number" and o > 0 then sid = o end
                    end
                    return { spellID = sid }
                end)
            elseif kind == "item" then
                MakePingable(frame, arcID, function() return { itemID = id } end)
            elseif kind == "trinket" then
                MakePingable(frame, arcID, function()
                    local itemID = GetInventoryItemID("player", id)
                    if itemID then return { itemID = itemID } end
                    return {}
                end)
            end
        end
    end
end


-- ═══════════════════════════════════════════════════════════════════════════
-- LAYOUT DESIGNER — the ONE thing AceConfig cannot host: the drag-and-drop
-- canvas (pieces + padding band). Everything numeric lives in the ArcUI
-- options panel; this small floating window is drag-only.
-- ═══════════════════════════════════════════════════════════════════════════

local designer
local designerRefresh

local WHITE = "Interface\\Buttons\\WHITE8X8"

local function GetLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

-- assigned, not declared: the auto-holder's OnAttributeChanged (far above) needs
-- to refresh the panel when the toggle key flips Auto-Ping
ACNotify = function()
    local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if reg then reg:NotifyChange("ArcUI") end
end

-- ── guided tour hooks ───────────────────────────────────────────────────────
-- Most of the per-spell editor (mode, key override) only renders for a spell
-- the player has actually turned on, so the tour asks first and skips those
-- steps rather than pointing at controls that are not there. The tour must
-- never enable a spell just to have something to show.
function Pings.TourHasTrackedSpell()
    local list = PKList()
    return list ~= nil and #list > 0
end

-- The tour wants to show the per-spell editor, which only renders once a spell
-- is selected. Prefer one the player has already set up (their own settings are
-- more meaningful to look at than a blank form), else the first on their bars.
-- Returns the selected subject id, or nil if there is nothing to show.
function Pings.TourSelectSpell()
    if PKSelectedID() then return PKSelectedID() end
    local list = PKList()
    if list and list[1] then
        PKSelect(list[1].id)
    else
        local cat = PKCatalog()
        if not (cat and cat[1]) then return nil end
        PKSelect(cat[1].id)
    end
    ACNotify()
    return PKSelectedID()
end

-- select mode edits the same list the Ping Keys panel shows: keep them in sync,
-- and put the user back in the panel they came from when they press Done
pkSel.notify = ACNotify
pkSel.onExit = function()
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    if not acd then return end
    acd:Open("ArcUI")
    acd:SelectGroup("ArcUI", "pings", "pingkeys")
    ACNotify()
end

local function BuildDesigner()
    if designer then return designer end
    local p = CreateFrame("Frame", "ArcUIPingsDesigner", UIParent, "BackdropTemplate")
    designer = p
    p:SetSize(560, 214)
    p:SetPoint("CENTER", 0, 140)
    p:SetFrameStrata("DIALOG")
    p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    p:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    p:SetBackdropColor(0.043, 0.059, 0.102, 0.97)
    p:SetBackdropBorderColor(0.165, 0.231, 0.341, 1)

    local title = p:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 13, "")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Pings|r  —  Layout Designer")
    local hint = p:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    hint:SetPoint("TOPLEFT", 12, -28)
    hint:SetTextColor(0.70, 0.78, 0.88)
    hint:SetText("drag pieces into place — drag the band's top/bottom edges for padding")
    local close = CreateFrame("Button", nil, p)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -4, -4)
    local cx = close:CreateFontString(nil, "OVERLAY")
    cx:SetFont(STANDARD_TEXT_FONT, 14, "")
    cx:SetPoint("CENTER")
    cx:SetText("x")
    cx:SetTextColor(0.70, 0.78, 0.88)
    close:SetScript("OnEnter", function() cx:SetTextColor(0.247, 0.788, 0.949) end)
    close:SetScript("OnLeave", function() cx:SetTextColor(0.70, 0.78, 0.88) end)
    close:SetScript("OnClick", function() p:Hide() end)

    -- canvas: clips, so nothing can ever bleed out of it
    local well = CreateFrame("Frame", nil, p, "BackdropTemplate")
    well:SetPoint("TOPLEFT", 10, -46)
    well:SetPoint("BOTTOMRIGHT", -10, 10)
    well:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    well:SetBackdropColor(0.039, 0.067, 0.125, 1)
    well:SetBackdropBorderColor(0.114, 0.165, 0.247, 1)
    well:SetClipsChildren(true)
    local midline = well:CreateTexture(nil, "BACKGROUND", nil, 1)
    midline:SetTexture(WHITE)
    midline:SetVertexColor(0.114, 0.165, 0.247, 0.35)
    midline:SetPoint("LEFT", 4, 0)
    midline:SetPoint("RIGHT", -4, 0)
    midline:SetHeight(1)

    -- the sample row (same render path as live rows)
    local sample = CreateFrame("Frame", nil, well)
    sample._isSample = true
    sample.line = CreateFrame("Frame", nil, sample)
    sample.line:SetHeight(1)
    sample.time = sample:CreateFontString(nil, "OVERLAY")
    sample.text = sample:CreateFontString(nil, "OVERLAY")
    sample.text:SetWordWrap(false)
    sample.sender = sample:CreateFontString(nil, "OVERLAY")
    sample.icon = sample:CreateTexture(nil, "ARTWORK")
    sample.icon:Hide()
    sample.time:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    sample.text:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    sample.sender:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    sample.time:SetText(date("%H:%M:%S"))
    sample:SetPoint("CENTER", well, "CENTER", 0, 0)
    sample:SetSize(280, 106)

    local function RenderSampleRow()
        sample.text:SetText(PreviewText(false))
        local _cls, playerClass = UnitClass("player")
        sample._senderClean = UnitName("player") or "Sender"
        ApplyRowLayout(sample)
    end

    -- the display-area band (shrink-wrapped box) + padding drag handles
    local bandF = CreateFrame("Frame", nil, sample)
    bandF:SetFrameLevel(sample:GetFrameLevel())
    local band = bandF:CreateTexture(nil, "BACKGROUND", nil, 2)
    band:SetTexture(WHITE)
    band:SetVertexColor(0.247, 0.788, 0.949, 0.07)
    band:SetAllPoints(bandF)

    local function BandHandle(side)
        local isTop = (side == "top")
        local h = CreateFrame("Frame", nil, well)
        h:SetFrameLevel(sample:GetFrameLevel() + 25)
        h:EnableMouse(true)
        h:SetHeight(8)
        if isTop then
            h:SetPoint("TOPLEFT", bandF, "TOPLEFT", 0, 4)
            h:SetPoint("TOPRIGHT", bandF, "TOPRIGHT", 0, 4)
        else
            h:SetPoint("BOTTOMLEFT", bandF, "BOTTOMLEFT", 0, -4)
            h:SetPoint("BOTTOMRIGHT", bandF, "BOTTOMRIGHT", 0, -4)
        end
        local tex = h:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(WHITE)
        tex:SetVertexColor(0.247, 0.788, 0.949, 0.12)
        tex:SetAllPoints()
        h:SetScript("OnEnter", function() tex:SetVertexColor(0.247, 0.788, 0.949, 0.5) end)
        h:SetScript("OnLeave", function() if not h._dragging then tex:SetVertexColor(0.247, 0.788, 0.949, 0.12) end end)
        h:SetScript("OnMouseDown", function()
            h._dragging = true
            local scale = sample:GetEffectiveScale()
            h:SetScript("OnUpdate", function()
                local _mx, my = GetCursorPosition()
                my = my / scale
                local _lcx, lineY = sample:GetCenter()
                if not lineY then return end
                local up, down = RowExtents()
                -- padding = distance from the piece extent to the cursor;
                -- clamps at 0 so the edge can NEVER cut into a piece
                local pad
                if isTop then pad = (my - lineY) - up
                else pad = (lineY - my) - down end
                pad = math.floor(pad + 0.5)
                if pad < 0 then pad = 0 elseif pad > 40 then pad = 40 end
                local key = isTop and "rowPadTop" or "rowPadBottom"
                if pad ~= Cfg(key) then SetCfg(key, pad) end
            end)
        end)
        h:SetScript("OnMouseUp", function()
            h._dragging = nil
            h:SetScript("OnUpdate", nil)
            tex:SetVertexColor(0.247, 0.788, 0.949, 0.12)
            ACNotify()
        end)
    end
    BandHandle("top"); BandHandle("bottom")

    -- draggable pieces (drop stores side + offsets; dragging detaches anchors)
    local PIECES = {
        time   = { el = sample.time,   label = "Timestamp", posKey = "timePos",   xKey = "timeX",   yKey = "timeY",   anchorKey = "timeAnchorTo" },
        sender = { el = sample.sender, label = "Sender",    posKey = "senderPos", xKey = "senderX", yKey = "senderY", anchorKey = "senderAnchorTo" },
        text   = { el = sample.text,   label = "Ping Text", posKey = "textPos",   xKey = "textX",   yKey = "textY" },
    }
    local UpdateTextGrip

    local function MakeDraggable(key)
        local pc = PIECES[key]
        local piece = pc.el
        local isText = (key == "text")
        local grip = CreateFrame("Button", nil, sample, "BackdropTemplate")
        grip:SetFrameLevel(sample:GetFrameLevel() + 10)
        grip:RegisterForDrag("LeftButton")
        grip:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
        grip:SetBackdropBorderColor(0.55, 0.65, 0.78, 0.6)
        if not isText then
            grip:SetPoint("TOPLEFT", piece, "TOPLEFT", -2, 2)
            grip:SetPoint("BOTTOMRIGHT", piece, "BOTTOMRIGHT", 2, -2)
        end
        local tag = grip:CreateFontString(nil, "OVERLAY")
        tag:SetFont(STANDARD_TEXT_FONT, 8, "")
        tag:SetPoint("BOTTOMLEFT", grip, "TOPLEFT", 0, 1)
        tag:SetTextColor(0.55, 0.65, 0.78)
        tag:SetText(pc.label)
        local hl = grip:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture(WHITE)
        hl:SetVertexColor(0.247, 0.788, 0.949, 0.15)
        hl:SetAllPoints()
        grip:SetScript("OnEnter", function()
            grip:SetBackdropBorderColor(0.247, 0.788, 0.949, 0.8)
            tag:SetTextColor(0.247, 0.788, 0.949)
        end)
        grip:SetScript("OnLeave", function()
            grip:SetBackdropBorderColor(0.55, 0.65, 0.78, 0.6)
            tag:SetTextColor(0.55, 0.65, 0.78)
        end)

        if isText then
            -- hug the glyph box (the fontstring itself spans the row)
            UpdateTextGrip = function()
                local w = (piece.GetStringWidth and piece:GetStringWidth() or 60) + 6
                local hgt = (Cfg("fontSize") or 12) + 8
                grip:SetSize(w, hgt)
                grip:ClearAllPoints()
                local tp = Cfg("textPos")
                if tp == "right" then
                    grip:SetPoint("RIGHT", piece, "RIGHT", 2, 0)
                elseif tp == "center" then
                    grip:SetPoint("CENTER", piece, "CENTER", 0, 0)
                else
                    grip:SetPoint("LEFT", piece, "LEFT", -2, 0)
                end
            end
            UpdateTextGrip()
        end

        local function PieceWidth()
            if isText then return (piece.GetStringWidth and piece:GetStringWidth() or 60) end
            return piece:GetWidth() or 16
        end
        local function PieceCenterX()
            if isText then
                local w = PieceWidth()
                local tp = Cfg("textPos")
                if tp == "right" then return (piece:GetRight() or 0) - w / 2 end
                if tp == "center" then local cxp = piece:GetCenter() return cxp or 0 end
                return (piece:GetLeft() or 0) + w / 2
            end
            local cxp = piece:GetCenter()
            return cxp or 0
        end

        local dragging, grabDX, grabDY
        grip:SetScript("OnDragStart", function()
            dragging = true
            local scale = sample:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            mx, my = mx / scale, my / scale
            local pcx = PieceCenterX()
            local _cx2, pcy = piece:GetCenter()
            grabDX, grabDY = (pcx or mx) - mx, (pcy or my) - my
            grip:SetScript("OnUpdate", function()
                local ux, uy = GetCursorPosition()
                ux, uy = ux / scale, uy / scale
                piece:ClearAllPoints()
                piece:SetPoint("CENTER", UIParent, "BOTTOMLEFT", ux + grabDX, uy + grabDY)
            end)
        end)
        grip:SetScript("OnDragStop", function()
            if not dragging then return end
            dragging = false
            grip:SetScript("OnUpdate", nil)
            local pcx, pcy = piece:GetCenter()
            local sl, sb = sample:GetLeft() or 0, sample:GetBottom() or 0
            local sw, sh = sample:GetWidth() or 1, sample:GetHeight() or 1
            if not (pcx and pcy) then designerRefresh() return end
            local relX = pcx - sl
            local relY = pcy - (sb + sh / 2)
            local half = sh / 2 - 10
            if relY > half then relY = half elseif relY < -half then relY = -half end
            local pw = PieceWidth()
            -- dragging = free placement: detach any piece anchor first
            if pc.anchorKey then DB()[pc.anchorKey] = "row" end
            if pc.posKey and pc.xKey then
                if relX < sw / 2 then
                    DB()[pc.posKey] = "left"
                    local x = math.floor(relX - pw / 2 + 0.5)
                    DB()[pc.xKey] = (x > 0) and x or 0
                else
                    DB()[pc.posKey] = "right"
                    local x = math.floor((sw - relX) - pw / 2 + 0.5)
                    DB()[pc.xKey] = (x > 0) and x or 0
                end
            end
            if pc.yKey then DB()[pc.yKey] = math.floor(relY + 0.5) end
            ApplyAll()
            designerRefresh()
            ACNotify()
        end)
    end
    MakeDraggable("time"); MakeDraggable("sender"); MakeDraggable("text")

    designerRefresh = function()
        local avail = (well:GetWidth() or 0) - 16
        if avail < 100 then avail = 520 end
        local winW = math.max(160, tonumber(Cfg("width")) or 340)
        sample:SetScale((winW > avail) and (avail / winW) or 1)
        sample:SetWidth(winW - 12)
        sample:SetHeight(106)
        sample.time:SetShown(Cfg("showTimestamp") and true or false)
        sample.sender:SetShown(Cfg("showSender") and true or false)
        local up, down = RowExtents()
        local padT, padB = RowPads()
        bandF:SetSize(winW, up + padT + down + padB)
        bandF:ClearAllPoints()
        bandF:SetPoint("CENTER", sample, "CENTER", 0, ((up + padT) - (down + padB)) / 2)
        RenderSampleRow()
        if UpdateTextGrip then UpdateTextGrip() end
    end

    p:SetScript("OnShow", function()
        designerRefresh()
        -- live sample ping in the REAL window while designing (real pings win)
        ShowPreviewEntry()
    end)
    p:SetScript("OnHide", function()
        if RemovePreviewEntries() then Render() end
    end)
    p:Hide()
    return p
end

designerNotify = function()
    if designer and designer:IsShown() and designerRefresh then designerRefresh() end
end

function Pings.ToggleDesigner()
    local d = BuildDesigner()
    d:SetShown(not d:IsShown())
end

-- ── boot / slash ─────────────────────────────────────────────────────────────
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function()
    -- One-time promotion of the keys from per-character to account-wide. Runs
    -- before anything reads them so the first character to log in after the
    -- change keeps the key it already bound instead of finding it blank. Only
    -- fills EMPTY account values, so it can never clobber a key set on an alt.
    local g = GlobalDB()
    -- Promote this character's window/entry/alert setup to the account base.
    -- Only fills values the account does not have yet, so the FIRST character
    -- to log in seeds it and later alts leave it alone rather than each one
    -- overwriting the last. Anything an alt genuinely wants different becomes
    -- an override, which is the whole point of the layer.
    if g and not g.pkScopeMigrated then
        g.pkScopeMigrated = true
        local c = DB()
        -- DEEP copy. `pos` is mutated in place (Render backfills pos.top /
        -- pos.bottom, and a scale change rescales them), so handing the account
        -- store the character's own table would alias the two and let one
        -- scope's drag rewrite another's. Same trap the castbar DB note calls
        -- out for global.castbars.
        local function CopyDeep(v)
            if type(v) ~= "table" then return v end
            local t = {}
            for kk, vv in pairs(v) do t[kk] = CopyDeep(vv) end
            return t
        end
        for k, v in pairs(c) do
            if not PK_CHAR_ONLY[k] and g[k] == nil then
                g[k] = CopyDeep(v)
            end
        end
    end
    -- ENTERING_WORLD also re-sweeps pingable icons (Arc frames rebuild on load)
    ApplyAll()
    -- Icons are created on Arc Auras' own schedule, mostly AFTER this boot
    -- sweep -- which left them unpingable until the options panel's next
    -- ApplyAll (Arc's "doesn't work until I open the panel" bug). Hook the
    -- single creation chokepoint with a debounced re-sweep: zero idle cost,
    -- fires only when an icon is actually created.
    if ns.ArcAuras and ns.ArcAuras.CreateFrame and not Pings._createHooked then
        Pings._createHooked = true
        local pending = false
        hooksecurefunc(ns.ArcAuras, "CreateFrame", function()
            if pending then return end
            pending = true
            C_Timer.After(0.5, function()
                pending = false
                Pings.RefreshPingable()
            end)
        end)
    end
    -- while the ArcUI options panel is open, a preview ping keeps the real
    -- window VISIBLE so people can see it and know where to drag it
    -- (Castbar ShowPreview pattern; real pings replace the preview)
    if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
        ns.CDMShared.RegisterPanelCallback("Pings", {
            onOpen = function()
                if not (Pings.IsAvailable() and Cfg("enabled")) then return end
                panelOpen = true
                ApplyAll()   -- border + title show as a placement aid, even locked
                ShowPreviewEntry()
            end,
            onClose = function()
                panelOpen = false
                RemovePreviewEntries()
                -- closing the panel LOCKS the feed in place (Arc's call):
                -- placement is a panel-open activity; a feed left unlocked
                -- afterwards just catches stray drags
                local db = DB()
                if not db.locked then db.locked = true end
                ApplyAll()
            end,
        })
    end
end)

-- the standalone owns /arcpings + /pingfeed when it is loaded
if not STANDALONE_LOADED then
    SLASH_ARCPINGS1 = "/arcpings"
    SLASH_ARCPINGS2 = "/pingfeed"
    SlashCmdList["ARCPINGS"] = function()
        if ns.API and ns.API.OpenOptions then ns.API.OpenOptions() end
        local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
        if acd then acd:SelectGroup("ArcUI", "pings") end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS (ArcUI panel, native AceConfig look — Window/Entries/Alerts/Layout
-- sub-tabs; the drag canvas lives in the small Layout Designer window)
-- ═══════════════════════════════════════════════════════════════════════════

-- builtin alert sounds registered into LSM so the standard ArcUI sound picker
-- lists them alongside the ArcUI: pack and every SharedMedia sound
do
    local lsm = GetLSM()
    if lsm then
        lsm:Register("sound", "Arc Pings: Alarm", 567458)
        lsm:Register("sound", "Arc Pings: Bell", 566558)
        lsm:Register("sound", "Arc Pings: Warning", 567397)
        -- the OLD keys stay registered: a saved alertSound holds the NAME, so
        -- dropping these would orphan anyone who had already picked one
        lsm:Register("sound", "Arc Ping Feed: Alarm", 567458)
        lsm:Register("sound", "Arc Ping Feed: Bell", 566558)
        lsm:Register("sound", "Arc Ping Feed: Warning", 567397)
    end
end

local POS_VALUES  = { left = "Left", center = "Center", right = "Right", top = "Top", bottom = "Bottom" }
local POS_SORT    = { "left", "center", "right", "top", "bottom" }
local TEXTPOS_VALUES = { left = "Left", center = "Center", right = "Right" }
local TEXTPOS_SORT   = { "left", "center", "right" }

-- Which DB key each layout piece uses, so one editor can drive all three.
local PIECE_SHOW   = { time = "showTimestamp", sender = "showSender" }
local PIECE_ANCHOR = { time = "timeAnchorTo", sender = "senderAnchorTo" }
local PIECE_POS    = { time = "timePos",  sender = "senderPos",  text = "textPos" }
local PIECE_X      = { time = "timeX",    sender = "senderX",    text = "textX" }
local PIECE_Y      = { time = "timeY",    sender = "senderY",    text = "textY" }
local PIECE_SIZE   = { time = "timeSize", sender = "senderSize", text = "textSize" }
-- HOISTED. This was declared further down, AFTER PieceGroup, so the builder
-- captured it as a nil GLOBAL -- the error only appeared once every piece
local PIECE_COLOR  = { time = "colTime",  sender = "colSender",  text = "colText" }
local PIECE_LABEL  = { time = "Timestamp", sender = "Sender", text = "Ping Text" }

-- ALL THREE PIECES ON SCREEN AT ONCE (Arc's call). This used to be a "Editing"
-- dropdown driving one shared block, to keep the control count down -- but it
-- meant you could never compare two pieces without flipping between them.
--
-- Generated rather than written out three times: the controls are identical bar
-- which DB key they touch, so a builder keeps it one place to fix and cannot
-- drift between pieces.
local function PieceGroup(pk, ord)
    local function has(tbl) return tbl[pk] ~= nil end
    return {
        type = "group", name = PIECE_LABEL[pk], inline = true, order = ord,
        -- the Show switches live together up in Entry Globals; a piece that is
        -- turned off hides its whole block rather than leaving dead controls
        hidden = function()
            local k = PIECE_SHOW[pk]
            return k ~= nil and Cfg(k) == false
        end,
        args = {
            anchor = { type = "select", name = "Anchor To", width = 1.0, order = 2,
                hidden = function() return not has(PIECE_ANCHOR) end,   -- text IS the anchor target
                values = function()
                    if pk == "time" then
                        return { row = "Window Edge", sender = "Sender", text = "Ping Text" }
                    end
                    return { row = "Window Edge", time = "Timestamp", text = "Ping Text" }
                end,
                get = function() return Cfg(PIECE_ANCHOR[pk]) or "row" end,
                set = function(_, v) SetCfg(PIECE_ANCHOR[pk], v) end },
            pos = { type = "select", name = "Position", width = 1.0, order = 3,
                desc = "Relative to the window edge, or to the anchored piece (\"Right\" = right of it).",
                values = function() return (pk == "text") and TEXTPOS_VALUES or POS_VALUES end,
                sorting = function() return (pk == "text") and TEXTPOS_SORT or POS_SORT end,
                get = function() return Cfg(PIECE_POS[pk]) end,
                set = function(_, v) SetCfg(PIECE_POS[pk], v) end },
            x = { type = "range", name = "X Offset", min = -600, max = 900, step = 1, width = 1.0, order = 4,
                get = function() return Cfg(PIECE_X[pk]) end,
                set = function(_, v) SetCfg(PIECE_X[pk], v) end },
            y = { type = "range", name = "Y Offset", min = -200, max = 200, step = 1, width = 1.0, order = 5,
                get = function() return Cfg(PIECE_Y[pk]) end,
                set = function(_, v) SetCfg(PIECE_Y[pk], v) end },
            size = { type = "range", name = "Font Size (0 = global)", min = 0, max = 48, step = 1, width = 1.2, order = 6,
                get = function() return Cfg(PIECE_SIZE[pk]) end,
                set = function(_, v) SetCfg(PIECE_SIZE[pk], v) end },
            color = { type = "color", name = "Color", width = 0.8, order = 7,
                get = function() local c = Cfg(PIECE_COLOR[pk]); return c[1], c[2], c[3] end,
                set = function(_, r, g, b) SetCfg(PIECE_COLOR[pk], { r, g, b }) end },
        },
    }
end

local function ColorOpt(name, key, order, extra)
    local o = {
        type = "color", name = name, order = order, width = 1.0,
        get = function()
            local c = Cfg(key)
            return c[1], c[2], c[3]
        end,
        set = function(_, r, g, b) SetCfg(key, { r, g, b }) end,
    }
    if extra then for k, v in pairs(extra) do o[k] = v end end
    return o
end

-- ── Ping Keys options ───────────────────────────────────────────────────────
-- One inline group per tracked spell, built once at PK_MAX and hidden when the
-- slot is empty (AceConfig has no dynamic list widget, and rebuilding the tree
-- on every add/remove would fight the open panel).
local function PKOptionArgs()
    local a = {
        desc = { type = "description", order = 1, fontSize = "medium",
            name = "Call your cooldowns out to the group without editing a macro.\n" },
        standalone = { type = "description", order = 1.5, fontSize = "small",
            name = "|cff8298b4Also available without ArcUI: search \"Arc Pings\" on CurseForge for the standalone addon.|r\n" },
        -- SETUP: the ping key and what it covers. Grouped so the three controls
        -- that describe one behaviour stay together at any panel width.
        setup = {
            type = "group", name = "Ping Key", inline = true, order = 2, width = 0.49,
            args = {
                pkEnabled = { type = "toggle", name = "Enable Ping Keys", width = 1.0, order = 1,
                    disabled = function() return not PKUsable() end,
                    get = function() return Cfg("pkEnabled") == true end,
                    set = function(_, v) SetCfg("pkEnabled", v) end },
                -- Row 1 reads left to right as the setup order: turn it on,
                -- bind the key, then narrow the scope if you want to.
                pkKey = { type = "keybinding", name = "Ping Key", width = 0.75, order = 2,
                    hidden = function() return not (PKUsable() and Cfg("pkEnabled")) end,
                    desc = "Hold this, then press a spell's own action bar key to ping it instead of casting. A spare mouse button works well. Individual spells can override this with their own ping key.\n\n"
                        .. "|cff8298b4Follows the scope picker at the top of this panel.|r",
                    get = function() return Cfg("pkKey") or "" end,
                    set = function(_, v) SetCfg("pkKey", v or "") end },
                pkOnlySelected = { type = "toggle", name = "Only Selected Spells", width = "full", order = 3,
                    hidden = function() return not (PKUsable() and Cfg("pkEnabled")) end,
                    desc = "By default the ping key works on every spell you have bound. Turn this on to restrict it to the spells you pick below. Spells you pick keep their own settings either way.",
                    get = function() return Cfg("pkOnlySelected") == true end,
                    set = function(_, v) SetCfg("pkOnlySelected", v); ACNotify() end },
            },
        },
        -- The two keys side by side, in their own group so they always pair.
        -- Auto-Ping has no checkbox: the toggle key IS the control, and a
        -- checkbox beside it just duplicated the same state.
        keyGroup = {
            type = "group", name = "Auto-Ping", inline = true, order = 3, width = 0.49,
            hidden = function() return not (PKUsable() and Cfg("pkEnabled")) end,
            args = {
                -- Row 2: the switch first, then the key that flips it. Reading
                -- "Auto-Ping ... Toggle Auto-Ping" left to right says what the
                -- key does without needing a caption under it.
                pkAutoOnToggle = { type = "toggle", name = "Auto-Ping", width = 1.0, order = 1,
                    desc = "Master switch for every spell set to \"Every time I press its key\".\n\n"
                        .. "Follows the Toggle Auto-Ping key, so this box updates when you press it — and you can flip it here if you would rather not bind a key at all.",
                    get = function() return PKAutoOn() end,
                    set = function(_, v)
                        DB().pkAutoOn = v and true or false
                        PKAutoNotify(v and true or false)
                        PKApply(); ACNotify()
                    end },
                pkToggleKey = { type = "keybinding", name = "Toggle Auto-Ping", width = 0.75, order = 2,
                    desc = "Silences and restores every spell set to \"Every time I press its key\", without losing them. Works in combat, so you can go quiet mid-pull.\n\n"
                        .. "|cff8298b4Follows the scope picker at the top of this panel.|r",
                    get = function() return Cfg("pkToggleKey") or "" end,
                    set = function(_, v) SetCfg("pkToggleKey", v or "") end },
                -- second row, so this box matches the Ping Key box's height and
                -- the two start at the same Y. It is not filler: nothing else
                -- says WHICH spells the master switch governs.
                autoNote = { type = "description", order = 3, width = "full",
                    name = "|cff8298b4Covers every spell set to \"Every time I press its key\". Spells on their own key ignore it.|r" },
            },
        },
        status = { type = "description", order = 5, fontSize = "medium",
            name = function()
                if not PKUsable() then
                    return STANDALONE_LOADED and " " or "|cffff5555Requires Patch 12.1.|r"
                end
                if not Cfg("pkEnabled") then return "|cff8298b4Off.|r" end
                local total, resolved = #PKList(), PKResolvedCount()
                local key = Cfg("pkKey")
                local needKey = (not key or key == "")
                if needKey and not Cfg("pkOnlySelected") then
                    return "|cffff5555Set a ping key.|r"
                end
                if not Cfg("pkOnlySelected") then
                    -- both layers run: the ping key covers everything, and the
                    -- picked list adds per-spell behaviour on top
                    if total == 0 then
                        return ("|cff33ff99Active:|r hold %s over any bound spell to ping it."):format(key)
                    end
                    return ("|cff33ff99Active:|r hold %s over any bound spell, plus %d of %d with their own settings.")
                        :format(key, resolved, total)
                end
                if total == 0 then return "|cff8298b4No spells selected yet.|r" end
                if resolved == 0 then return "|cffff5555None of them will ping — see the reasons below.|r" end
                return ("|cff33ff99Active:|r %d of %d."):format(resolved, total)
            end },
        catHdr = { type = "header", name = "Per-Spell Settings", order = 6,
            hidden = function() return not Cfg("pkEnabled") end },
        catSearch = { type = "input", name = "Search", width = 1.0, order = 6.1,
            hidden = function() return not Cfg("pkEnabled") end,
            desc = "Filter the list below by name.",
            get = function() return pkCatSearch end,
            set = function(_, v) pkCatSearch = v or ""; ACNotify() end },
        catView = { type = "select", name = "Show", width = 1.0, order = 6.15,
            hidden = function() return not Cfg("pkEnabled") end,
            values = { all = "All", on = "Pinging", off = "Not Pinging" },
            sorting = { "all", "on", "off" },
            get = function() return PKGetCatView() end,
            set = function(_, v) PKSetCatView(v); ACNotify() end },
        catRescan = { type = "execute", name = "Rescan Bars", width = 1.0, order = 6.2,
            hidden = function() return not Cfg("pkEnabled") end,
            desc = "Re-read your action bars. Runs automatically when you move a spell or change a keybind.",
            func = function() PKCatalogDirty(); PKBuildCatalog(); ACNotify() end },
        catHint = { type = "description", order = 6.05, fontSize = "medium",
            hidden = function() return not Cfg("pkEnabled") end,
            name = "Pick a spell to give it something different — its own ping key, a ping on every cast, or a key that only pings.\n" },
        catCount = { type = "description", order = 6.3, fontSize = "medium",
            hidden = function() return not Cfg("pkEnabled") end,
            name = function()
                local all = PKCatalog()
                local shown = #PKCatalogFiltered()
                local keyed = 0
                for i = 1, #all do if all[i].key then keyed = keyed + 1 end end
                if shown < #all then
                    return ("|cff8298b4Showing %d of %d — %d have a keybind.|r"):format(shown, #all, keyed)
                end
                return ("|cff8298b4%d on your bars, %d with a keybind. Click one to add it.|r"):format(#all, keyed)
            end },
        addCursor = { type = "execute", name = "Pick On My Bars", width = 1.0, order = 6.25,
            disabled = function() return not PKUsable() end,
            hidden = function() return not Cfg("pkEnabled") end,
            desc = "Closes this window and lights up your action bars so you can click the spells you want directly. Same result as clicking them here.",
            func = function()
                -- close the options window so the bars are clear to click
                local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
                if acd then acd:Close("ArcUI") end
                PKEnterSelect()
            end },
        rowBreak3 = { type = "description", name = "", order = 6.255, width = "full",
            hidden = function() return not Cfg("pkEnabled") end },
        addID = { type = "input", name = "Add By Spell ID", width = 1.0, order = 6.26,
            disabled = function() return not PKUsable() end,
            hidden = function() return not Cfg("pkEnabled") end,
            desc = "For anything not on a bar. It appears in the grid with the rest and works fully once you give it a Key Override.",
            get = function() return "" end,
            set = function(_, v)
                local sid = tonumber(v)
                if not sid or sid <= 0 then return end
                local list = PKList()
                if #list >= PK_MAX then
                    print("|cff33ff99ArcUI Pings|r: ping-key list is full (" .. PK_MAX .. " entries).")
                    return
                end
                for i = 1, #list do
                    if list[i].id == sid then PKSelect(sid); ACNotify(); return end
                end
                list[#list + 1] = { id = sid }
                DB().pkSpells = list
                PKCatalogDirty()
                PKSelect(sid)
                PKApply()
                ACNotify()
            end },
        -- ── SELECTED ICON EDITOR ────────────────────────────────────────────
        -- One editor for whichever icon is clicked, instead of an inline group
        -- per tracked spell. The old list grew without bound and buried the
        -- catalog; this keeps the panel a fixed height no matter how many
        -- spells are tracked.
        selHdr = { type = "header", order = 20,
            hidden = function() return not Cfg("pkEnabled") or PKSelected() == nil end,
            name = function()
                local e = PKSelected()
                if not e then return "" end
                return ("|T%d:18:18:0:0:64:64:5:59:5:59|t %s"):format(e.icon or 134400, e.name or "?")
            end },
        selStatus = { type = "description", order = 20.1, fontSize = "medium",
            hidden = function() return not Cfg("pkEnabled") or PKSelected() == nil end,
            name = function()
                local e = PKSelected()
                if not e then return "" end
                local t = PKTracked(e.id)
                local barKey = e.key   -- the key your action bar has it on
                if not t then
                    return barKey and ("|cff8298b4Bar key:|r %s"):format(barKey)
                        or "|cffff5555No keybind on your bars — only \"Its own key\" will work.|r"
                end
                local mode = PKEntryMode(t)
                -- Paused rather than broken: the guard in PKEntryMatchesBar
                -- refuses to hijack a bar key whose slot has changed (spec
                -- swap, spell moved). Say so, or it looks like nothing happens.
                if mode ~= "own" and not PKEntryMatchesBar(t) then
                    return "|cffffd100Paused — this spell is not on that bar slot right now"
                        .. " (spec change or moved).|r Put it back and it resumes on its own."
                end
                if mode == "own" then
                    local k = t.ownKey
                    if not k or k == "" then
                        return "|cffff5555Set a key below — this mode needs one.|r"
                    end
                    return ("|cff8298b4Press|r |cffffd100%s|r |cff8298b4on its own to ping. Nothing is cast.|r"):format(k)
                end
                if not barKey then
                    return "|cffff5555No keybind on your bars — this mode needs one. Bind it, or switch to \"Its own key\".|r"
                end
                if mode == "always" then
                    return ("|cff8298b4Casts and pings on|r %s"):format(barKey)
                end
                local pk = PKPingKeyFor(t)
                if not pk then return "|cffff5555No ping key set.|r" end
                local own = t.pingKey and t.pingKey ~= ""
                return ("|cff8298b4Hold|r |cffffd100%s|r|cff8298b4%s then press|r %s"):format(
                    pk, own and " (this spell only)" or "", barKey)
            end },
        selEnable = { type = "toggle", name = "Ping This Spell", width = 1.0, order = 20.2,
            hidden = function() return not Cfg("pkEnabled") or PKSelected() == nil end,
            get = function() local t = PKTracked((PKSelected() or {}).id); return PKEntryOn(t) and t ~= nil end,
            set = function(_, v) PKSetSelectedEnabled(v); ACNotify() end },
        -- Press gate. Only meaningful for the mode that fires on every press;
        -- hold- and own-key modes are already deliberate, so it stays hidden
        -- there rather than sitting greyed out.
        selEvery = { type = "select", name = "Presses Per Ping", width = 1.2, order = 20.35,
            hidden = function()
                local t = PKTracked((PKSelected() or {}).id)
                return not Cfg("pkEnabled") or t == nil or PKEntryMode(t) ~= "always"
            end,
            desc = "Spamming the key sends a ping every single press. Raise this and only every Nth press pings.\n\n"
                .. "|cffff5555Counts presses, not seconds|r — the count does not reset over time, so with 2 it is always the 2nd, 4th, 6th press that pings, however far apart. Your cast always goes through either way.",
            values = { [1] = "Every press", [2] = "Every 2nd press", [3] = "Every 3rd press",
                       [4] = "Every 4th press", [5] = "Every 5th press" },
            sorting = { 1, 2, 3, 4, 5 },
            get = function()
                local t = PKTracked((PKSelected() or {}).id)
                return (t and tonumber(t.every)) or 1
            end,
            set = function(_, v)
                local t = PKTracked((PKSelected() or {}).id)
                if not t then return end
                t.every = (v > 1) and v or nil
                DB().pkSpells = PKList(); PKApply(); ACNotify()
            end },
        -- (no time- or cooldown-based option here: nothing can carry that state
        -- into the decision during combat -- see the four tested dead ends at
        -- PK_PRESS_GATE. Press count is what is left.)
        selMode = { type = "select", name = "Pings When", width = 1.0, order = 20.3,
            hidden = function()
                local t = PKTracked((PKSelected() or {}).id)
                return not Cfg("pkEnabled") or t == nil
            end,
            values = {
                key    = "I hold the ping key",
                always = "Every time I press its key",
                own    = "Its own key (ping only)",
            },
            sorting = { "key", "always", "own" },
            get = function()
                local t = PKTracked((PKSelected() or {}).id)
                return t and PKEntryMode(t) or "key"
            end,
            set = function(_, v)
                local t = PKTracked((PKSelected() or {}).id)
                if not t then return end
                t.mode = (v ~= "key") and v or nil
                DB().pkSpells = PKList(); PKApply(); ACNotify()
            end },
        -- Hold mode only: which ping key wakes THIS spell. The global Ping Key
        -- covers everything by default; this is for putting one spell on a
        -- different modifier. It does NOT change the spell's bar key.
        selPingKey = { type = "keybinding", name = "Ping Key For This Spell", width = 1.0, order = 20.4,
            hidden = function()
                local t = PKTracked((PKSelected() or {}).id)
                return not Cfg("pkEnabled") or t == nil or PKEntryMode(t) ~= "key"
            end,
            desc = "Optional. Hold THIS key instead of your global Ping Key to ping this one spell. You still press the spell's normal action bar key alongside it. Leave empty to use the global Ping Key.",
            get = function() local t = PKTracked((PKSelected() or {}).id); return (t and t.pingKey) or "" end,
            set = function(_, v)
                local t = PKTracked((PKSelected() or {}).id)
                if not t then return end
                t.pingKey = (v and v ~= "") and v or nil
                DB().pkSpells = PKList(); PKApply(); ACNotify()
            end },
        -- Own-key mode only: the one key that pings this spell outright.
        selOwnKey = { type = "keybinding", name = "Key", width = 1.0, order = 20.45,
            hidden = function()
                local t = PKTracked((PKSelected() or {}).id)
                return not Cfg("pkEnabled") or t == nil or PKEntryMode(t) ~= "own"
            end,
            desc = "Press this key on its own to ping the spell. Nothing is cast, so use a key you have spare — good for calling out that something is on cooldown.",
            get = function() local t = PKTracked((PKSelected() or {}).id); return (t and t.ownKey) or "" end,
            set = function(_, v)
                local t = PKTracked((PKSelected() or {}).id)
                if not t then return end
                t.ownKey = (v and v ~= "") and v or nil
                DB().pkSpells = PKList(); PKApply(); ACNotify()
            end },
        selRemove = { type = "execute", name = "Remove", width = 1.0, order = 20.5,
            hidden = function()
                local t = PKTracked((PKSelected() or {}).id)
                return not Cfg("pkEnabled") or t == nil
            end,
            desc = "Forget this spell entirely, including its keys. Turning \"Ping This Spell\" off instead keeps them.",
            func = function() PKRemoveSelected(); ACNotify() end },
    }
    -- CATALOG GRID (orders 7.x): one execute-with-image per bar subject, the
    -- same shape the Cooldown Reminder catalog uses. Clicking SELECTS -- the
    -- editor above is where enable / mode / key / remove live.
    local entries = PKCatalogFiltered()
    for i = 1, #entries do
        if i > PK_CAT_MAX then break end
        local e = entries[i]
        a["cat" .. i] = {
            type = "execute", order = 7 + i / 1000, width = 0.22,
            hidden = function() return not Cfg("pkEnabled") end,
            name = function()
                -- the grid has no selection ring in AceConfig, so the marker
                -- carries both states: what is being edited, and what is armed
                if PKSelectedID() == e.id then return "|cffffd100>|r" end
                local t = PKTracked(e.id)
                if not t then return " " end
                return PKEntryOn(t) and "|cff33ff99*|r" or "|cff8298b4*|r"
            end,
            image = e.icon, imageWidth = 28, imageHeight = 28,
            desc = function()
                local t = ("|cffffd100%s|r"):format(e.name or "?")
                t = t .. (e.key and ("\n|cff8298b4Key: " .. e.key .. "|r")
                                or "\n|cffff5555No keybind — cannot be pinged|r")
                if e.kind == "item" then t = t .. "\n|cff8298b4Item|r" end
                local tr = PKTracked(e.id)
                if tr then
                    t = t .. (PKEntryOn(tr) and "\n\n|cff33ff99Pinging|r" or "\n\n|cff8298b4Added, turned off|r")
                end
                return t .. "\n\n|cff8298b4Click to edit|r"
            end,
            func = function() PKSelect(e.id); ACNotify() end,
        }
    end
    return a
end

function ns.GetPingsOptionsTable()
    if STANDALONE_LOADED then
        return {
            type = "group", name = "Pings",
            args = {
                sa = { type = "description", order = 1, fontSize = "medium",
                    name = "The standalone |cff33ff99Arc Pings|r addon is loaded — configure it there (/arcpings). ArcUI's built-in feed is dormant so the two never fight.\n" },
                -- pingable Arc icons are ArcUI-only and always on, so nothing to
                -- configure here -- just say they still work
                iconsDesc = { type = "description", order = 2, fontSize = "medium",
                    hidden = function() return not HAS_ACTION_PINGS end,
                    name = "Your ArcUI spell icons stay pingable either way — hover one and press your Ping key to call it out.\n" },
            },
        }
    end
    if not HAS_ACTION_PINGS then
        return {
            type = "group", name = "Pings",
            args = {
                soon = { type = "header", name = "Coming in Patch 12.1", order = 1 },
                preview = { type = "description", order = 2, fontSize = "medium",
                    name = "\n|cff33ff99Arc Pings|r arrives with Midnight's ping rework:\n\n"
                        .. "|cffffd100Feed window|r — every ping your group sends (spell callouts, ready/on-cooldown states, warnings) collected in a movable, fully styleable feed window: free layout designer, fonts, colors, animations, scale, class-colored senders.\n\n"
                        .. "|cffffd100Ping Alerts|r — Cooldown-Reminder-style alert sounds when your group pings, with throttling and the full ArcUI sound library.\n\n"
                        .. "|cffffd100Pingable Arc Icons|r — hover any ArcUI spell icon and press your Ping keybind to call it out, exactly like the native cooldown icons.\n\n"
                        .. "This panel activates automatically on a 12.1 client — nothing to install or enable.\n" },
            },
        }
    end
    return {
        type = "group", name = "Pings", childGroups = "tab",
        args = {
            -- SCOPE PICKER LIVES ON THE PARENT, NOT IN A TAB.
            -- AceConfig renders a group's non-group args ABOVE its tab strip,
            -- so putting it here shows it exactly once for Window / Entries /
            -- Alerts / Ping Keys instead of repeating the same control in each.
            -- It has to be visible from every tab because it decides where that
            -- tab's edits land.
            scopeHdr = { type = "header", name = "Editing", order = 0.001 },
            -- "Changes I Make Apply To", not "These Settings Apply To": this is
            -- an editing MODE, not a switch that relocates the whole config.
            -- The old wording implied all-or-nothing and caused exactly the
            -- "can I have keys global but the window per-character?" confusion.
            pkEditScope = { type = "select", name = "Changes I Make Apply To", width = 1.3, order = 0.002,
                desc = "This does NOT move everything to that scope — it decides where the NEXT thing you change is kept.\n\n"
                    .. "So you can pick |cff7ec9f2Only <you>|r, move the window, and only the window is yours. Ping keys, entries and anything else you did not touch keep following the account, including later changes to it.\n\n"
                    .. "Setting by setting, never all-or-nothing.",
                values = function()
                    local v = { [SCOPE_ACCOUNT] = "All My Characters" }
                    v[SCOPE_CHAR] = "Only " .. (UnitName("player") or "This Character")
                    if SpecKey() then
                        -- no character name here: you are standing on that
                        -- character, so "Only Enhancement" can only mean this one
                        local i = GetSpecialization()
                        local _id, nm = GetSpecializationInfo(i)
                        v[SCOPE_SPEC] = "Only " .. (nm or "This Spec")
                    end
                    return v
                end,
                sorting = function()
                    local s = { SCOPE_ACCOUNT, SCOPE_CHAR }
                    if SpecKey() then s[#s + 1] = SCOPE_SPEC end
                    return s
                end,
                get = function() return ActiveScope() end,
                set = function(_, v)
                    DB().pkEditScope = (v ~= SCOPE_ACCOUNT) and v or nil
                    ApplyAll(); ACNotify()
                end },
            scopeState = { type = "description", order = 0.003, fontSize = "medium", width = 1.7,
                name = function()
                    local scope = ActiveScope()
                    local t = OvTable(scope, false)
                    local n = 0
                    if t then for _k in pairs(t) do n = n + 1 end end
                    -- terse on purpose: this shares a row with the picker now,
                    -- so a full sentence would wrap and put the height straight back
                    if scope == SCOPE_ACCOUNT then
                        return "|cff8298b4Shared by everyone.|r"
                    end
                    if n == 0 then
                        return "|cff8298b4Following the account — change anything to break out.|r"
                    end
                    return ("|cff33ff99%d overridden.|r |cff8298b4Rest follow the account.|r"):format(n)
                end },
            scopeClear = { type = "execute", name = "Reset This Scope", width = 1.0, order = 0.004,
                hidden = function()
                    local t = OvTable(ActiveScope(), false)
                    if not t then return true end
                    for _k in pairs(t) do return false end
                    return true
                end,
                desc = "Drops every override in this scope so it follows the account settings again. Other characters and specs are untouched.",
                func = function()
                    local g, k = GlobalDB(), ScopeKey(ActiveScope())
                    if g and g._ov and k then g._ov[k] = nil end
                    ApplyAll(); ACNotify()
                end },
            window = {
                type = "group", name = "Window", order = 2, childGroups = "tab",
                args = {
                    blizzWarn = { type = "description", order = 0.1, fontSize = "medium",
                        hidden = function() return BlizzPingSettingsOK() end,
                        name = "|cffff5555The Blizzard setting \"Show Pings in Chat\" (or \"Enable Pings\") is turned OFF -- the game sends addons nothing, so the feed stays empty.|r" },
                    blizzFix = { type = "execute", name = "Fix Blizzard Ping Settings", width = 1.6, order = 0.2,
                        hidden = function() return BlizzPingSettingsOK() end,
                        desc = "Turns on \"Enable Pings\" and \"Show Pings in Chat\" in the Blizzard options so the feed receives pings.",
                        func = function() FixBlizzPingSettings(); ApplyAll() end },
                    -- master switch on its own row: everything below is about a
                    -- window that only exists when this is on
                    enabled = { type = "toggle", name = "Enable Feed Window", width = 2.0, order = 1,
                        get = function() return Cfg("enabled") end,
                        set = function(_, v) SetCfg("enabled", v) end },
                    -- live-preview + panic button, kept beside the master
                    -- toggle so they are reachable from either sub-panel
                    testPing = { type = "execute", name = "Show Test Ping", width = 1.2, order = 3,
                        desc = "Adds a sample ping to the real window so you can see your layout live.",
                        func = function() AddEntry(PreviewText(true), UnitName("player")) end },
                    resetAll = { type = "execute", name = "Reset Whole Layout", width = 1.2, order = 4, confirm = true,
                        desc = "Back to the Blizzard chat shape: sender at the line start, callout flowing after, automatic height.",
                        func = function()
                            local db = DB()
                            db.showTimestamp = false; db.showSender = true
                            db.timePos = "left"; db.timeX = 0; db.timeY = 0
                            db.senderPos = "right"; db.senderX = 0; db.senderY = 0
                            db.textPos = "left"; db.textX = 0; db.textY = 0
                            db.timeAnchorTo = "row"; db.senderAnchorTo = "time"
                            db.timeSize = 0; db.senderSize = 0; db.textSize = 0
                            db.rowPadTop = 2; db.rowPadBottom = 2
                            SetCfg("enabled", Cfg("enabled"))  -- one ApplyAll + designer refresh
                        end },

                    -- SUB-PANELS. The window itself (where it sits, how big,
                    -- how it is skinned) is a different job from the lines
                    -- inside it, and as flat headers they scrolled into one
                    -- long wall. Nested groups give Window its own tab strip;
                    -- the toggle above stays outside so it governs both.
                    frame = {
                        type = "group", name = "Window Layout", order = 1,
                        hidden = function() return not Cfg("enabled") end,
                        args = {
                            posHdr = { type = "header", name = "Position", order = 5,
                                hidden = function() return not Cfg("enabled") end },
                            posGroup = {
                                type = "group", name = "", inline = true, order = 6,
                                hidden = function() return not Cfg("enabled") end,
                                args = {
                                    -- Typed coordinates, for placing it exactly or
                                    -- matching another character without dragging.
                                    -- Offsets from the SCREEN CENTRE, which is what the
                                    -- window is anchored by, so 0,0 is dead centre.
                                    -- Y follows the grow direction: it is the top edge
                                    -- with newest-on-top, the bottom edge otherwise --
                                    -- the same edge dragging preserves.
                                    posX = { type = "range", name = "X", width = 0.9, order = 0.1,
                                        min = -2000, max = 2000, step = 1, softMin = -960, softMax = 960,
                                        desc = "Horizontal offset from the centre of the screen. Negative is left.",
                                        get = function() local p = Cfg("pos"); return (p and p[1]) or 0 end,
                                        set = function(_, v) SetWindowPos(v, nil) end },
                                    posY = { type = "range", name = "Y", width = 0.9, order = 0.2,
                                        min = -2000, max = 2000, step = 1, softMin = -540, softMax = 540,
                                        desc = "Vertical offset from the centre of the screen. Negative is down.\n\n"
                                            .. "This is the edge the window grows away from, so it stays put as entries come and go.",
                                        get = function()
                                            local p = Cfg("pos")
                                            if not p then return 0 end
                                            local top = Cfg("newestOnTop") ~= false
                                            return (top and p.top) or (not top and p.bottom) or p[2] or 0
                                        end,
                                        set = function(_, v) SetWindowPos(nil, v) end },
                                    locked = { type = "toggle", name = "Lock Window Position", width = 1.4, order = 1,
                                        get = function() return Cfg("locked") end,
                                        set = function(_, v) SetCfg("locked", v) end },
                                    panelDrag = { type = "toggle", name = "Drag While Options Open", width = 1.4, order = 2,
                                        desc = "While this options panel is open, the window can be dragged into place even when its position is locked. Turn off if you want the lock respected at all times.",
                                        get = function() return Cfg("panelDrag") ~= false end,
                                        set = function(_, v) SetCfg("panelDrag", v) end },
                                    showTitle = { type = "toggle", name = "Show Title While Unlocked", width = 1.6, order = 3,
                                        desc = "The \"Arc Pings\" label floating above the window while it is unlocked or this options panel is open. It sits outside the window and never touches the entries.",
                                        get = function() return Cfg("showTitle") ~= false end,
                                        set = function(_, v) SetCfg("showTitle", v) end },
                                },
                            },

                            -- WHERE the feed may appear. Switching a content type off
                            -- stops the window AND stops listening for pings there, so
                            -- nothing piles up out of sight. Instance type only changes
                            -- across a loading screen, so none of this needs combat.
                            showInHdr = { type = "header", name = "Show In", order = 7,
                                hidden = function() return not Cfg("enabled") end },
                            showInGroup = {
                                type = "group", name = "", inline = true, order = 8,
                                hidden = function() return not Cfg("enabled") end,
                                args = (function()
                                    local list = {
                                        { "showInWorld", "Open World", 1,
                                          "Anywhere that is not an instance." },
                                        { "showInDungeon", "Dungeons", 2,
                                          "Normal, Heroic and Mythic 0. Mythic Plus has its own switch." },
                                        { "showInMythicPlus", "Mythic Plus", 3 },
                                        { "showInRaid", "Raids", 4 },
                                        { "showInBattleground", "Battlegrounds", 5 },
                                        { "showInArena", "Arenas", 6 },
                                        { "showInScenario", "Scenarios and Delves", 7,
                                          "Scenarios, delves and follower dungeons." },
                                    }
                                    local args = {}
                                    for _i, e in ipairs(list) do
                                        local key = e[1]
                                        args[key] = { type = "toggle", name = e[2], order = e[3],
                                            width = 1.2, desc = e[4],
                                            get = function() return Cfg(key) ~= false end,
                                            set = function(_, v) SetCfg(key, v) end }
                                    end
                                    return args
                                end)(),
                            },

                            sizeHdr = { type = "header", name = "Size", order = 10,
                                hidden = function() return not Cfg("enabled") end },
                            -- width/height belong together, and Static Size changes what
                            -- height even means, so all three ride in one group
                            sizeGroup = {
                                type = "group", name = "", inline = true, order = 11,
                                hidden = function() return not Cfg("enabled") end,
                                args = {
                                    width = { type = "range", name = "Window Width", order = 1,
                                        min = 160, max = 900, step = 10, width = 1.4,
                                        desc = "The window's base width. If a callout needs more room, the window widens for it and returns afterwards — readable callouts are never cut off.",
                                        get = function() return Cfg("width") end,
                                        set = function(_, v) SetCfg("width", v) end },
                                    height = { type = "range", name = "Window Height", order = 2,
                                        min = 0, max = 800, step = 10, width = 1.4,
                                        desc = "0 = automatic: the window hugs its entries. Set a value to keep the window at least this tall — it still grows when more entries need the room.",
                                        get = function() return Cfg("height") end,
                                        set = function(_, v) SetCfg("height", v) end },
                                    staticSize = { type = "toggle", name = "Static Window Size", width = 1.4, order = 3,
                                        desc = "The window is always sized for Max Entries Shown and stays on screen even when empty — a fixed box that pings flow through, instead of a window that grows and shrinks with each ping.",
                                        get = function() return Cfg("staticSize") end,
                                        set = function(_, v) SetCfg("staticSize", v) end },
                                },
                            },
                            scaleGroup = {
                                type = "group", name = "", inline = true, order = 12,
                                hidden = function() return not Cfg("enabled") end,
                                args = {
                                    windowScale = { type = "range", name = "Window Scale", order = 1,
                                        min = 0.5, max = 2, step = 0.05, isPercent = true, width = 1.4,
                                        get = function() return Cfg("windowScale") end,
                                        set = function(_, v) SetCfg("windowScale", v) end },
                                    strata = { type = "select", name = "Window Layer", width = 1.4, order = 2,
                                        desc = "Which UI layer the window draws on. Raise it if something covers the feed.",
                                        values = { BACKGROUND = "Background (lowest)", LOW = "Low", MEDIUM = "Medium", HIGH = "High", DIALOG = "Dialog (highest)" },
                                        sorting = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG" },
                                        get = function() return Cfg("strata") end,
                                        set = function(_, v) SetCfg("strata", v) end },
                                },
                            },

                            bgHeader = { type = "header", name = "Backdrop", order = 20,
                                hidden = function() return not Cfg("enabled") end },
                            -- each backdrop layer is its own group: the toggle and the
                            -- settings it controls stay together however wide the panel
                            -- gets, and the settings hide entirely when it is off
                            bgGroup = {
                                type = "group", name = "", inline = true, order = 21,
                                hidden = function() return not Cfg("enabled") end,
                                args = {
                                    showBackground = { type = "toggle", name = "Show Background", width = 1.4, order = 1,
                                        get = function() return Cfg("showBackground") end,
                                        set = function(_, v) SetCfg("showBackground", v) end },
                                    colBg = ColorOpt("Background Color", "colBg", 2,
                                        { hidden = function() return not Cfg("showBackground") end }),
                                    bgAlpha = { type = "range", name = "Background Opacity", order = 3,
                                        min = 0, max = 1, step = 0.05, isPercent = true, width = 1.4,
                                        hidden = function() return not Cfg("showBackground") end,
                                        get = function() return Cfg("bgAlpha") end,
                                        set = function(_, v) SetCfg("bgAlpha", v) end },
                                },
                            },
                            borderGroup = {
                                type = "group", name = "", inline = true, order = 22,
                                hidden = function() return not Cfg("enabled") end,
                                args = {
                                    showBorder = { type = "toggle", name = "Show Border", width = 1.4, order = 1,
                                        desc = "The border always shows while the window is unlocked, as a placement aid.",
                                        get = function() return Cfg("showBorder") end,
                                        set = function(_, v) SetCfg("showBorder", v) end },
                                    colBorder = ColorOpt("Border Color", "colBorder", 2,
                                        { hidden = function() return not Cfg("showBorder") end }),
                                },
                            },
                        },
                    },
                    entries = {
                        type = "group", name = "Entries Behavior", order = 3,
                        hidden = function() return not Cfg("enabled") end,
                        args = {
                            maxEntries = { type = "range", name = "Max Entries Shown", order = 35,
                                min = 1, max = 20, step = 1, width = 1.4,
                                get = function() return Cfg("maxEntries") end,
                                set = function(_, v) SetCfg("maxEntries", v) end },
                            entrySeconds = { type = "range", name = "Entry Duration (seconds)", order = 36,
                                min = 0, max = 60, step = 1, width = 1.4,
                                desc = "How long each ping stays in the window. 0 = stay until pushed out.",
                                get = function() return Cfg("entrySeconds") end,
                                set = function(_, v) SetCfg("entrySeconds", v) end },
                            newestOnTop = { type = "toggle", name = "Newest Entries On Top", width = 1.4, order = 37,
                                get = function() return Cfg("newestOnTop") end,
                                set = function(_, v) SetCfg("newestOnTop", v) end },
                            -- the two paddings belong together; same inline-group trick
                            padGroup = {
                                type = "group", name = "", inline = true, order = 38,
                                args = {
                                    rowPadTop = { type = "range", name = "Top Padding", order = 1,
                                        min = 0, max = 40, step = 1, width = 1.4,
                                        desc = "Space between the tallest piece and the entry's top edge. The entry box always hugs your layout; padding adds breathing room.",
                                        get = function() return Cfg("rowPadTop") end,
                                        set = function(_, v) SetCfg("rowPadTop", v) end },
                                    rowPadBottom = { type = "range", name = "Bottom Padding", order = 2,
                                        min = 0, max = 40, step = 1, width = 1.4,
                                        get = function() return Cfg("rowPadBottom") end,
                                        set = function(_, v) SetCfg("rowPadBottom", v) end },
                                },
                            },
                            -- KEEPING A PAIR TOGETHER: AceConfig widths are ABSOLUTE
                            -- pixels (width_multiplier = 170 per 1.0 unit), not a share
                            -- of the panel. So a wider panel simply fits more controls
                            -- per row and any pairing set by width falls apart -- the
                            -- Expire dropdown rode up next to Entrance and left its own
                            -- slider stranded below.
                            --
                            -- An inline group is the only thing that binds them: it
                            -- flows its children INSIDE itself, so they wrap as a unit
                            -- and never mix with controls outside. Unnamed so it costs a
                            -- box but no extra heading line.
                            animInGroup = {
                                type = "group", name = "", inline = true, order = 39,
                                args = {
                                    animStyle = { type = "select", name = "New Ping Animation", width = 1.4, order = 1,
                                        values = { none = "None", fade = "Fade In", pulse = "Pulse", flash = "Flash", zoom = "Zoom (pop in)" },
                                        sorting = { "none", "fade", "pulse", "flash", "zoom" },
                                        get = function() return Cfg("animStyle") end,
                                        set = function(_, v) SetCfg("animStyle", v) end },
                                    animInSecs = { type = "range", name = "Entrance Duration (seconds)", order = 2,
                                        min = 0.1, max = 2, step = 0.1, width = 1.4,
                                        hidden = function() return Cfg("animStyle") == "none" end,
                                        get = function() return Cfg("animInSecs") end,
                                        set = function(_, v) SetCfg("animInSecs", v) end },
                                },
                            },
                            animOutGroup = {
                                type = "group", name = "", inline = true, order = 40,
                                args = {
                                    animOutStyle = { type = "select", name = "Expire Animation", width = 1.4, order = 1,
                                        values = { none = "None (snap off)", fade = "Fade Out" },
                                        sorting = { "none", "fade" },
                                        get = function() return Cfg("animOutStyle") end,
                                        set = function(_, v) SetCfg("animOutStyle", v) end },
                                    animOutSecs = { type = "range", name = "Fade Out Duration (seconds)", order = 2,
                                        min = 0.1, max = 3, step = 0.1, width = 1.4,
                                        hidden = function() return Cfg("animOutStyle") ~= "fade" end,
                                        get = function() return Cfg("animOutSecs") end,
                                        set = function(_, v) SetCfg("animOutSecs", v) end },
                                },
                            },
                        },
                    },
                    entrylayout = {
                        type = "group", name = "Entry Layout", order = 2,
                        hidden = function() return not Cfg("enabled") end,
                        args = {
                            entHdr = { type = "header", name = "Entry Globals", order = 29.9,
                                hidden = function() return not Cfg("enabled") end },
                            -- Two ROWS, bound by inline groups. Widths cannot do this: AceConfig
                            -- widths are absolute pixels, so a wider panel just fits more per row
                            -- and any pairing set by width falls apart (same lesson as the
                            -- animation pairs). A group flows its children inside itself.
                            fontGroup = {
                                type = "group", name = "", inline = true, order = 30,
                                args = {
                                fontSize = { type = "range", name = "Font Size", order = 1,
                                    min = 8, max = 24, step = 1, width = 1.4,
                                    get = function() return Cfg("fontSize") end,
                                    set = function(_, v) SetCfg("fontSize", v) end },
                                fontOutline = { type = "select", name = "Font Outline", width = 1.4, order = 2,
                                    values = { NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline" },
                                    sorting = { "NONE", "OUTLINE", "THICKOUTLINE" },
                                    get = function() return Cfg("fontOutline") end,
                                    set = function(_, v) SetCfg("fontOutline", v) end },
                                },
                            },
                            -- the per-piece blocks below hold PLACEMENT; whether a piece exists at
                            -- all is a property of the entry, so both switches live up here together
                            layoutHdr = { type = "header", name = "Pieces", order = 44 },
                            layoutGroup = {
                                type = "group", name = "", inline = true, order = 45,
                                args = {
                                desc = { type = "description", order = 1, fontSize = "small",
                                    name = "Every piece of an entry is listed below. Place them here, or drag them visually in the Layout Designer. The entry box always shrink-wraps whatever you build.\n" },
                                openDesigner = { type = "execute", name = "Open Layout Designer", width = 1.4, order = 2,
                                    desc = "A small window where you drag the pieces into place and drag the box edges to trim the padding.",
                                    func = function() Pings.ToggleDesigner() end },
                                -- riding the Designer's row: widths kept tight so the pair sits
                                -- together rather than drifting apart across the panel
                                showSender = { type = "toggle", name = "Show Sender", width = 0.9, order = 2.1,
                                    desc = "Who sent the ping. Turning this off hides its placement settings below.",
                                    get = function() return Cfg("showSender") ~= false end,
                                    set = function(_, v) SetCfg("showSender", v); ACNotify() end },
                                showTimestamp = { type = "toggle", name = "Show Timestamp", width = 0.9, order = 2.2,
                                    desc = "Off by default — the feed reads cleaner without it. Turning it on reveals its placement settings below.",
                                    get = function() return Cfg("showTimestamp") == true end,
                                    set = function(_, v) SetCfg("showTimestamp", v); ACNotify() end },
                                -- every piece expanded; see PieceGroup for why it is generated
                                senderPiece = PieceGroup("sender", 10),
                                textPiece   = PieceGroup("text",   11),
                                timePiece   = PieceGroup("time",   12),
                                },
                            },
                        },
                    },
                },
            },
            alerts = {
                type = "group", name = "Alerts", order = 4,
                args = {
                    alertsEnabled = { type = "toggle", name = "Enable Ping Alerts", width = 1.4, order = 1,
                        desc = "Plays a sound whenever your group pings.",
                        get = function() return Cfg("alertsEnabled") end,
                        set = function(_, v) SetCfg("alertsEnabled", v) end },
                    alertSound = { type = "select", name = "Alert Sound", width = 1.4, order = 2,
                        dialogControl = "LSM30_Sound",
                        values = function()
                            local lsm = GetLSM()
                            return lsm and lsm:HashTable("sound") or { None = "None" }
                        end,
                        disabled = function() return not Cfg("alertsEnabled") end,
                        get = function() return Cfg("alertSound") end,
                        set = function(_, v) SetCfg("alertSound", v) end },
                    alertThrottle = { type = "range", name = "Minimum Seconds Between Alerts", order = 3,
                        min = 0, max = 10, step = 0.5, width = 1.8,
                        disabled = function() return not Cfg("alertsEnabled") end,
                        get = function() return Cfg("alertThrottle") end,
                        set = function(_, v) SetCfg("alertThrottle", v) end },
                    test = { type = "execute", name = "Test Alert", width = 1.0, order = 4,
                        func = function()
                            local f = ResolveSound(Cfg("alertSound"))
                            if f then PlaySoundFile(f, "Master") end
                        end },
                },
            },
            pingkeys = {
                type = "group", name = "Ping Keys", order = 1,
                args = PKOptionArgs(),
            },
        },
    }
end

