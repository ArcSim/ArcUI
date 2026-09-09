-- ═══════════════════════════════════════════════════════════════════════════
-- Arc Loot Planner - roll ledger + Adventure Guide markers + bonus roll protection
--
-- Standalone twin (an ArcUI module version mirrors this file; keep in sync).
--
-- SAFETY INVARIANTS (the reason this addon exists over the alternatives):
--   * This addon NEVER calls AcceptSpellConfirmationPrompt or
--     DeclineSpellConfirmationPrompt. Under any code path. The only thing
--     that can roll or pass is the player's own click on Blizzard's own
--     LIVE button — so rolling the wrong boss from stale addon state is
--     structurally impossible, not merely guarded.
--   * Protection is a CLICK-BLOCKING COVER over Blizzard's button, purely
--     subtractive. Worst possible failure = a cover shown or hidden
--     wrongly (an inconvenience), never an action.
--   * No SetScript on Blizzard frames (replaces their handlers, taints the
--     binding). Only hooksecurefunc + our own child frames.
--   * Identity = encounterID + difficultyID + weekly-reset bucket, per
--     character. Never localized name strings.
--
-- Marking model (per Arc's design):
--   * BOSS rows in the Adventure Guide carry the PLANNED-BOSS picker (a
--     coin; click = save this week's coin for that boss; star = planned;
--     a small check badge = rolled this week, from the automatic ledger).
--   * LOOT rows carry the item-level state: bright check = won from a
--     recorded roll, cyan check = manually checked off ("I already got
--     this from a roll" — the only possible backfill, there is no history
--     API), faint coin = click to check it off. Un-collected items show
--     an estimated share (1 in N eligible drops under the current filter).
--     The roll's overall success rate is server-side and never shown.
--
-- /abr — options window (Arc theme). /abr mock — cover test. No pcall.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, NS = ...
local AT = NS.AT

-- ═══ ArcUI TWIN of the standalone Arc Loot Planner addon ══════════════════════
-- FULL PARITY PORT (ArcPings pattern). Keep in sync with the standalone:
-- every fix lands in BOTH copies in the same session. Differences here:
-- dormancy below, AceDB storage in InitDB, minimap default OFF (ArcUI's
-- options-default-false rule), wipe scope, and the AceConfig launcher tab.
-- Dormant when the standalone is present: it owns the feature and this file
-- creates NOTHING (no frames, no slash, no events, no hooks). The standalone
-- was renamed Arc Loot Planner -> Arc Loot Planner (2026-09-06); match both.
if C_AddOns and C_AddOns.IsAddOnLoaded
    and (C_AddOns.IsAddOnLoaded("ArcLootPlanner") or C_AddOns.IsAddOnLoaded("ArcBonusRoll")) then
    NS.BonusRollDormant = true
    return
end

local COLOR = "|cff33ccff"
local function Print(msg)
    print(COLOR .. "Arc Loot Planner|r: " .. msg)
end

local TEX_CHECK = "common-icon-checkmark"                       -- atlas
local TEX_COIN  = "Interface\\Buttons\\UI-GroupLoot-Coin-Up"    -- last-resort fallback
local TEX_LOCK  = "Interface\\PetBattles\\PetBattle-LockIcon"

-- Nebulous Voidcore, the 12.1 bonus roll currency (Arc-confirmed in-game;
-- the FrameXML BONUS_ROLL_REQUIRED_CURRENCY constant still says 697, the
-- legacy Seal, so do not trust it). A prompt-learned ID overrides this.
local BONUS_CURRENCY = 3418

-- fake spellID for /abr test prompts: recognizably not a real spell, and
-- AcceptSpellConfirmationPrompt on it is a server-side no-op (no pending
-- confirmation exists), so clicking through a test prompt does NOTHING
local TEST_SPELL_ID = 999999901

-- ── DB ──────────────────────────────────────────────────────────────────────
local db, char   -- set in InitDB at login

local function CharKey()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then
        realm = (GetRealmName() or ""):gsub("%s", "")
    end
    return (name or "Unknown") .. "-" .. realm
end

-- The upcoming weekly reset's timestamp IDs the week (constant all week,
-- jumps at reset). Rounded to the hour to absorb clock skew.
local function CurrentWeek()
    local untilReset = C_DateAndTime.GetSecondsUntilWeeklyReset() or 0
    local reset = GetServerTime() + untilReset
    return math.floor((reset + 1800) / 3600) * 3600
end

-- ArcUI twin MASTER SWITCH (OFF by default - ArcUI's opt-in rule; the
-- standalone addon has no such flag, installing it IS the opt-in there).
-- Every user-visible surface and every background pass gates on this.
local function ModuleEnabled()
    return char ~= nil and char.settings ~= nil and char.settings.enabled == true
end

-- Per-spec stores: the live aliases every reader/writer uses.
-- RelinkSpecStores points them at the current spec's saved buckets (see
-- the InitDB comment). Until a spec is known (early-login race) they are
-- detached empties, and the first import/prime relinks before writing.
local simStore, poolStore, poolPrimed = {}, {}, {}
local storesLinked = false

local function CurrentSpecID()
    local idx = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and C_SpecializationInfo.GetSpecialization() or nil
    return idx and C_SpecializationInfo.GetSpecializationInfo(idx) or nil
end

local function CurrentSpecName()
    local idx = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and C_SpecializationInfo.GetSpecialization() or nil
    if not idx then return "?" end
    local _, name = C_SpecializationInfo.GetSpecializationInfo(idx)
    return name or "?"
end

local function RelinkSpecStores()
    if not (db and char) then return end
    local specID = CurrentSpecID()
    if not specID then return end
    char.specData = char.specData or {}
    local mine = char.specData[specID] or {}
    char.specData[specID] = mine
    db.poolBySpec = db.poolBySpec or {}
    local shared = db.poolBySpec[specID] or {}
    db.poolBySpec[specID] = shared
    -- one-time adoption of the pre-per-spec stores into today's spec
    if char.simEV and next(char.simEV) and not mine.simEV then mine.simEV = char.simEV end
    if char.poolCache and next(char.poolCache) and not shared.cache then shared.cache = char.poolCache end
    if char.poolPrimedAt and next(char.poolPrimedAt) and not shared.primedAt then shared.primedAt = char.poolPrimedAt end
    char.simEV, char.poolCache, char.poolPrimedAt = nil, nil, nil
    mine.simEV = mine.simEV or {}
    shared.cache = shared.cache or {}
    shared.primedAt = shared.primedAt or {}
    simStore = mine.simEV
    poolStore = shared.cache
    poolPrimed = shared.primedAt
    storesLinked = true
end

-- ── Shipped pool seed ───────────────────────────────────────────────────────
-- NS.PoolSeed (the generated data file) carries every class and spec's
-- loot tables, extracted once via TokenLab from the game's own journal
-- database. At login the player's OWN class specs are expanded into the
-- account pool store (presence only - never overwriting a link the
-- primer has attached), so every page renders fully on the very first
-- open. The background primer stays on as the verifier: it attaches
-- real links and reconciles anything Blizzard changed.
local function SeedPools()
    local seed = NS.PoolSeed
    if not (seed and type(seed.specs) == "table" and db) then return end
    local classID = select(3, UnitClass("player"))
    local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
        or GetNumSpecializationsForClassID
    local getInfo = GetSpecializationInfoForClassID
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
    local n = (classID and getNum) and getNum(classID) or 0
    db.poolBySpec = db.poolBySpec or {}
    for i = 1, n do
        local specID = getInfo and getInfo(classID, i)
        local sp = specID and seed.specs[specID]
        if sp then
            local store = db.poolBySpec[specID] or {}
            db.poolBySpec[specID] = store
            store.cache = store.cache or {}
            local cache = store.cache
            for _, d in ipairs({ 14, 15, 16, 17 }) do
                local bucket = cache[d] or {}
                cache[d] = bucket
                for inst, encs in pairs(sp.r or {}) do
                    for enc, ids in pairs(encs) do
                        local set = bucket[enc] or {}
                        bucket[enc] = set
                        for id in ids:gmatch("%d+") do
                            id = tonumber(id)
                            if set[id] == nil then set[id] = true end
                        end
                    end
                end
            end
            if type(sp.d) == "table" and next(sp.d) then
                cache.mplusBonus = cache.mplusBonus or {}
                for inst, ids in pairs(sp.d) do
                    local set = cache.mplusBonus[inst] or {}
                    cache.mplusBonus[inst] = set
                    for id in ids:gmatch("%d+") do
                        id = tonumber(id)
                        if set[id] == nil then set[id] = true end
                    end
                end
            end
        end
    end
end

local function InitDB()
    -- ArcUI twin storage: per-character data in ns.db.char.bonusRoll (AceDB's
    -- char scope already keys by character, so the standalone's chars[key]
    -- layer is unnecessary); account-wide data (poolBySpec) in
    -- ns.db.global.bonusRoll. ArcUI_Options creates the AceDB at PLAYER_LOGIN
    -- before this module's handler runs (toc order); boot() retries if not.
    if not (NS.db and NS.db.char and NS.db.global) then return end
    NS.db.global.bonusRoll = NS.db.global.bonusRoll or {}
    db = NS.db.global.bonusRoll
    NS.db.char.bonusRoll = NS.db.char.bonusRoll or {}
    char = NS.db.char.bonusRoll
    char.rolls = char.rolls or {}         -- ledger, newest first
    -- [itemID] = { [difficultyID] = time() } manual "already got it". The
    -- Voidcore tooltip says items are received ONCE PER DIFFICULTY LEVEL,
    -- so ownership is difficulty-scoped (0 = any, from legacy marks).
    char.itemMarks = char.itemMarks or {}
    for itemID, v in pairs(char.itemMarks) do
        if type(v) ~= "table" then char.itemMarks[itemID] = { [0] = v } end
    end
    -- [encounterID .. ":" .. difficultyID] = true - bosses the player has
    -- CHECKED OFF (done rolling: got everything, or just not interested).
    -- Persistent, per difficulty, toggled by right-clicking the boss coin.
    char.doneBosses = char.doneBosses or {}
    -- [week] = { ["enc:diff"] = true, ... } - planned bosses are PER
    -- DIFFICULTY (Heroic and Mythic planned separately), several allowed.
    -- Legacy shapes (single {encounterID=X}, and boss-level numeric keys)
    -- are dropped: plans are weekly and trivial to re-click.
    char.plan  = char.plan or {}
    for week, p in pairs(char.plan) do
        if type(p) ~= "table" then
            char.plan[week] = nil
        else
            if p.encounterID ~= nil then char.plan[week] = nil end
            if char.plan[week] then
                for k in pairs(p) do
                    if type(k) ~= "string" then p[k] = nil end
                end
                if not next(p) then char.plan[week] = nil end
            end
        end
    end
    char.marks = nil                      -- legacy weekly boss marks, removed
    char.settings = char.settings or {}
    local s = char.settings
    if s.protection == nil then s.protection = false end  -- opt-in
    if s.passGuard  == nil then s.passGuard  = true  end  -- sub-toggle of protection
    if s.ejOverlay  == nil then s.ejOverlay  = true  end
    if s.tooltips   == nil then s.tooltips   = true  end
    s.detectOwned = nil    -- legacy gate: a saved "false" from the old toggle
                           -- silently killed detection forever; it is gone
    s.stripPos = nil       -- legacy position picker: inside-top is THE spot now
    if s.showStrip == nil then s.showStrip = true end     -- journal info bar
    if s.stripCounter == nil then s.stripCounter = "total" end -- "total" | "week"
    if s.evPercent == nil then s.evPercent = false end    -- EV as % of baseline DPS
    if s.minimap == nil then s.minimap = false end        -- ArcUI rule: opt-in (standalone ships it ON)
    if s.minimapAngle == nil then s.minimapAngle = 210 end
    if s.planReminder == nil then s.planReminder = true end -- new-week plan nudge
    -- ArcUI twin ONLY: the module master switch. ON by default (Arc's
    -- explicit call, overriding the usual opt-in default for this module)
    if s.enabled == nil then s.enabled = true end
    if s.showOnRaids == nil then s.showOnRaids = true end     -- journal raid pages
    if s.showOnDungeons == nil then s.showOnDungeons = false end -- dungeon/M+ pages
    -- the two halves of the journal overlay, separately hideable: raw item
    -- DPS gains, and the bonus-roll dressing (coins, shares, planning)
    if s.showGains == nil then s.showGains = true end
    if s.showShares == nil then s.showShares = true end
    if s.lootRollSim == nil then s.lootRollSim = true end -- need/greed sim tag
    if char.rollBaseline == nil then char.rollBaseline = 0 end -- pre-install rolls
    -- sim EVs and confirmed pools are PER SPEC and PERSISTENT. Sims are
    -- gear-dependent, so they live per character: char.specData[specID]
    -- .simEV[diff] = { base, t, gains = { [enc] = { [itemID] = gain } } }.
    -- The journal pool is identical for every character of a spec, so it
    -- lives ACCOUNT-wide: db.poolBySpec[specID].cache[diff][enc] =
    -- { [itemID] = true }, .primedAt[diff] = journal instanceID. Primed
    -- ONCE, saved, and re-harvested only for a raid or spec this account
    -- has never confirmed. RelinkSpecStores aliases the live stores.
    RelinkSpecStores()
    SeedPools()

    local cutoff = CurrentWeek() - 8 * 7 * 24 * 3600
    for week in pairs(char.plan) do
        if type(week) ~= "number" or week < cutoff then char.plan[week] = nil end
    end
    while #char.rolls > 200 do table.remove(char.rolls) end
end

-- ── State queries ───────────────────────────────────────────────────────────
local lastKnownCurrencyID

local function BonusCurrencyID()
    return (char and char.lastCurrencyID) or lastKnownCurrencyID or BONUS_CURRENCY
end

local function CoinIconTexture()
    local id = BonusCurrencyID()
    if id then
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        if info and info.iconFileID then return info.iconFileID end
    end
    return TEX_COIN
end

local function BonusRollsAvailable()
    local id = BonusCurrencyID()
    if id then
        local info = C_CurrencyInfo.GetCurrencyInfo(id)
        if info then return info.quantity or 0, info.name end
    end
    return nil, nil
end

local wonItems = {}   -- [itemID] = { [difficultyID] = ledger record }

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function RememberWonItem(rec)
    local id = ItemIDFromLink(rec.link)
    if not id then return end
    wonItems[id] = wonItems[id] or {}
    if not wonItems[id][rec.diff or 0] then
        wonItems[id][rec.diff or 0] = rec
    end
end

local function RebuildWonItems()
    wipe(wonItems)
    for i = 1, #char.rolls do
        RememberWonItem(char.rolls[i])
    end
end

-- owned FOR A DIFFICULTY = won from a recorded roll on it, or checked off
-- (difficulty 0 = legacy "any difficulty" marks count everywhere)
local function IsOwnedItem(itemID, diff)
    if not itemID then return false, nil end
    local won = wonItems[itemID]
    if won and (won[diff] or won[0]) then return true, "auto", won[diff] or won[0] end
    local marks = char.itemMarks[itemID]
    if marks and (marks[diff] or marks[0]) then return true, "manual", nil end
    return false, nil, nil
end

-- RETRO-ESTIMATION (the Raidbots trick): figure out already-received pieces
-- without any roll history API. The EJ loot link carries THIS difficulty's
-- bonusIDs, so the transmog collection answers per difficulty version and
-- remembers forever, even for deleted gear. Non-transmoggable pieces
-- (trinkets, rings, necks) fall back to equipped+bags at the drop's base
-- item level or higher. Runs ONLY when the player presses Estimate looted,
-- and its hits are written as ORDINARY manual checks (same check, and the
-- player can un-click any of them) - never a passive overlay.
local detectCache = {}

local function WipeDetectCache()
    wipe(detectCache)
end

local function DetectOwnedByLink(link, itemID)
    if not link then return false end
    local hit = detectCache[link]
    if hit ~= nil then return hit end
    local owned = false
    -- transmog: SOURCE-level, never appearance-level. An alt's Normal copy
    -- shares the appearance and false-marked the Heroic drop (user report:
    -- Amani Summoning Shawl). PlayerKnowsSource answers for THIS
    -- difficulty's version of the item only.
    if C_TransmogCollection and C_TransmogCollection.GetItemInfo
        and C_TransmogCollection.PlayerKnowsSource then
        local _appearance, sourceID = C_TransmogCollection.GetItemInfo(link)
        if sourceID then
            owned = C_TransmogCollection.PlayerKnowsSource(sourceID) or false
        end
    end
    if not owned and itemID then
        -- equipped/bags: match the item, and accept the drop's base item
        -- level OR HIGHER (owned pieces are usually upgraded, an exact
        -- match almost never fires). A lower-difficulty version stays
        -- below the higher difficulty's base, so >= is the right gate.
        local wantIlvl = C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link) or nil
        local function SameItem(foundLink)
            if not foundLink then return false end
            if ItemIDFromLink(foundLink) ~= itemID then return false end
            -- STRICT on both ends (user report: a champion-track M+ copy
            -- claimed the raid drop while item levels were unreadable):
            -- when either item level cannot be read, claim NOTHING
            if not wantIlvl then return false end
            local il = C_Item.GetDetailedItemLevelInfo(foundLink)
            return il ~= nil and il >= wantIlvl
        end
        for slot = 1, 19 do
            if SameItem(GetInventoryItemLink("player", slot)) then
                owned = true
                break
            end
        end
        if not owned and C_Container then
            for bag = 0, 4 do
                local n = C_Container.GetContainerNumSlots(bag) or 0
                for s = 1, n do
                    if SameItem(C_Container.GetContainerItemLink(bag, s)) then
                        owned = true
                        break
                    end
                end
                if owned then break end
            end
        end
    end
    detectCache[link] = owned
    return owned
end


local function GetRollRecord(week, enc, diff)
    for i = 1, #char.rolls do
        local r = char.rolls[i]
        if r.week == week and r.enc == enc and r.diff == diff then
            return r
        end
    end
    return nil
end

local function BossKey(enc, diff)
    return tostring(enc) .. ":" .. tostring(diff or 0)
end

-- Mythic+ bonus rolls are planned per DUNGEON with ONE pool (all bosses'
-- loot together). Plans/marks/records reuse the boss machinery with the
-- dungeon's journal instanceID in the encounter slot under this canonical
-- difficulty key - instance IDs and encounter IDs never collide.
local MPLUS_DIFF = 8   -- Mythic Keystone

-- the journal's "Keystone Dungeons" AGGREGATE page (journal instance 1319
-- per wago.tools JournalInstance; no API flag marks it): it repeats loot
-- the real dungeons already list, so every M+ surface skips it - a coin
-- there would double-count the season's pool
local MPLUS_AGGREGATE_INSTANCE = 1319

local function PlanEntryName(enc, diff)
    if diff == MPLUS_DIFF and EJ_GetInstanceInfo then
        local n = EJ_GetInstanceInfo(enc)
        if n then return n end
    end
    return EJ_GetEncounterInfo(enc) or ("encounter " .. enc)
end

local function IsPlanned(week, enc, diff)
    local p = char.plan[week]
    return (p and enc and p[BossKey(enc, diff)]) and true or false
end

local function HasAnyPlan(week)
    local p = char.plan[week]
    return (p and next(p)) and true or false
end

local function PlannedNames(week)
    local p = char.plan[week]
    if not p then return nil end
    local names
    for key in pairs(p) do
        local enc, diff = key:match("^(%d+):(%d+)$")
        enc, diff = tonumber(enc), tonumber(diff)
        if enc then
            local n = PlanEntryName(enc, diff)
            local dn = diff and diff ~= 0 and GetDifficultyInfo(diff) or nil
            if dn then n = n .. " (" .. dn .. ")" end
            names = names and (names .. ", " .. n) or n
        end
    end
    return names
end

-- compact display form: one entry per boss with letter codes for its
-- planned difficulties - "The Coiled Altar (H)(M), Sszorak (N)"
local DIFF_CODE = { [14] = "N", [15] = "H", [16] = "M", [17] = "L", [MPLUS_DIFF] = "M+" }
local function PlannedShort(week)
    local p = char.plan[week]
    if not p then return nil, 0 end
    local byBoss, order, entryNames = {}, {}, {}
    for key in pairs(p) do
        local enc, diff = key:match("^(%d+):(%d+)$")
        enc, diff = tonumber(enc), tonumber(diff)
        if enc then
            if not byBoss[enc] then
                byBoss[enc] = {}
                order[#order + 1] = enc
            end
            if not entryNames[enc] then entryNames[enc] = PlanEntryName(enc, diff) end
            local code = DIFF_CODE[diff]
            if not code and diff and diff ~= 0 then
                local dn = GetDifficultyInfo(diff)
                code = dn and dn:sub(1, 1) or "?"
            end
            table.insert(byBoss[enc], code or "?")
        end
    end
    local parts, count = {}, 0
    for _, enc in ipairs(order) do
        table.sort(byBoss[enc])
        local codes = ""
        for _, c in ipairs(byBoss[enc]) do codes = codes .. "(" .. c .. ")" end
        parts[#parts + 1] = (entryNames[enc] or ("boss " .. enc)) .. " " .. codes
        count = count + 1
    end
    return table.concat(parts, ", "), count
end

local function EncounterName(encounterID)
    if not encounterID or encounterID == 0 then return "unknown boss" end
    local name = EJ_GetEncounterInfo(encounterID)
    return name or ("encounter " .. encounterID)
end

local function DifficultyName(diff)
    if not diff or diff == 0 then return "?" end
    local name = GetDifficultyInfo(diff)
    return name or ("difficulty " .. diff)
end

-- forward declarations (defined below, used by the recording engine)
local RefreshEJ
local UpdateCovers
local RefreshWindow
local WipeLootPool
local ApplyMinimapButton
local MaybePlanReminder
local HidePlanReminder
local InstallVaultHook
local simStatusMsg = ""   -- Sims tab status line (writers live above the window code)

-- ── Recording engine ────────────────────────────────────────────────────────
-- BONUS_ROLL_STARTED = the player committed the coin: record NOW, with the
-- boss identity read live from Blizzard's own frame fields at that instant
-- (set by BonusRollFrame_StartBonusRoll; reading Blizzard fields is safe).
local pendingRoll

local function OnRollStarted()
    if not ModuleEnabled() then return end
    if not char then return end
    local f = BonusRollFrame
    local rec = {
        week = CurrentWeek(),
        enc  = (f and f.encounterID) or 0,
        diff = (f and f.difficultyID) or 0,
        inst = (f and f.instanceID) or 0,
        t = time(),
        result = "pending",
    }
    table.insert(char.rolls, 1, rec)
    while #char.rolls > 200 do table.remove(char.rolls) end
    pendingRoll = rec
    if RefreshEJ then RefreshEJ() end
    if RefreshWindow then RefreshWindow() end
end

local function OnRollResult(typeIdentifier, itemLink, quantity, _, _, _, currencyID)
    if not ModuleEnabled() then return end
    if not char or not pendingRoll then return end
    pendingRoll.result = typeIdentifier or "?"
    pendingRoll.link = itemLink
    pendingRoll.qty = quantity
    pendingRoll.currencyID = currencyID
    RememberWonItem(pendingRoll)
    pendingRoll = nil
    if WipeLootPool then WipeLootPool() end
    if RefreshEJ then RefreshEJ() end
    if RefreshWindow then RefreshWindow() end
end

local function OnRollFailed()
    if not ModuleEnabled() then return end
    if pendingRoll then
        pendingRoll.result = "failed"
        pendingRoll = nil
        if RefreshWindow then RefreshWindow() end
    end
end

-- ── Coin protection covers ──────────────────────────────────────────────────
-- Our own child frames over Blizzard's buttons. We never write to, disable,
-- or re-script the real buttons — Blizzard's own OnShow re-enables the dice
-- button anyway, so covering is both safer and the only stable approach.
local rollCover, passCover
local promptToken, unlockedRoll, unlockedPass

local function MakeCover(anchorButton, unlockKind)
    local c = CreateFrame("Button", nil, BonusRollFrame.PromptFrame)
    c:SetPoint("TOPLEFT", anchorButton, "TOPLEFT", -3, 3)
    c:SetPoint("BOTTOMRIGHT", anchorButton, "BOTTOMRIGHT", 3, -3)
    c:SetFrameLevel(anchorButton:GetFrameLevel() + 5)
    c:EnableMouse(true)
    c:RegisterForClicks("AnyUp")
    local bg = c:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.78)
    local lock = c:CreateTexture(nil, "OVERLAY")
    lock:SetSize(16, 16)
    lock:SetPoint("CENTER")
    lock:SetTexture(TEX_LOCK)
    c.reason = ""
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Arc Loot Planner protection", 0.2, 0.8, 1)
        GameTooltip:AddLine(self.reason, 1, 1, 1, true)
        GameTooltip:AddLine("Click this cover once to unlock the button underneath for this prompt.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnClick", function()
        if unlockKind == "roll" then unlockedRoll = true else unlockedPass = true end
        GameTooltip:Hide()
        UpdateCovers()
    end)
    c:Hide()
    return c
end

local function EnsureCovers()
    if rollCover then return true end
    local pf = BonusRollFrame and BonusRollFrame.PromptFrame
    if not (pf and pf.RollButton and pf.PassButton) then return false end
    rollCover = MakeCover(pf.RollButton, "roll")
    passCover = MakeCover(pf.PassButton, "pass")
    return true
end

UpdateCovers = function()
    if not char then return end
    if not ModuleEnabled() then
        if rollCover then rollCover:Hide() end
        if passCover then passCover:Hide() end
        return
    end
    -- every plan toggle routes through here: the moment a plan exists, the
    -- "plan your week" reminder has done its job
    if HidePlanReminder and HasAnyPlan(CurrentWeek()) then HidePlanReminder() end
    if not EnsureCovers() then return end
    local showRoll, showPass = false, false
    local rollReason, passReason = "", ""
    local pf = BonusRollFrame.PromptFrame
    if char.settings.protection and pf:IsShown() then
        local week = CurrentWeek()
        local enc = BonusRollFrame.encounterID
        local diff = BonusRollFrame.difficultyID
        -- an M+ bonus roll is planned per DUNGEON: match the prompt's
        -- instance against the dungeon plan too (raid instances can never
        -- carry a :8 key - only dungeon coins write those)
        local inst = BonusRollFrame.instanceID
        local isPlannedHere = (enc and IsPlanned(week, enc, diff))
            or (inst and IsPlanned(week, inst, MPLUS_DIFF))
        if not HasAnyPlan(week) then
            showRoll = not unlockedRoll
            rollReason = "No planned bosses are set for this week. Pick them in the Adventure Guide (click the coin on a boss), or unlock to roll anyway."
        elseif isPlannedHere then
            showPass = char.settings.passGuard and not unlockedPass
            local target
            if enc and IsPlanned(week, enc, diff) then
                target = EncounterName(enc)
            else
                target = inst and PlanEntryName(inst, MPLUS_DIFF) or "this dungeon"
            end
            passReason = ("This is on your planned list (%s) - passing would throw away the roll you saved your coin for."):format(target)
        else
            showRoll = not unlockedRoll
            rollReason = ("Your coins are saved for: %s. Unlock to roll this boss anyway."):format(PlannedNames(week) or "?")
        end
    end
    rollCover.reason = rollReason
    passCover.reason = passReason
    rollCover:SetShown(showRoll)
    passCover:SetShown(showPass)
end

local function OnPromptShown()
    local f = BonusRollFrame
    if not f then return end
    -- a /abr test prompt must not pollute the learned currency/instance
    if f.spellID ~= TEST_SPELL_ID then
        if f.CurrentCountFrame and f.CurrentCountFrame.currencyID then
            lastKnownCurrencyID = f.CurrentCountFrame.currencyID
            if char then char.lastCurrencyID = lastKnownCurrencyID end
        end
        if char and f.instanceID and f.instanceID ~= 0 then
            char.lastInstanceID = f.instanceID   -- "open the journal here" target
        end
    end
    local token = tostring(f.spellID) .. ":" .. tostring(f.encounterID) .. ":" .. tostring(f.difficultyID)
    if token ~= promptToken then
        promptToken = token
        unlockedRoll, unlockedPass = nil, nil
    end
    UpdateCovers()
    -- a roll is up with nothing planned: protection is covering nothing,
    -- which is exactly when the plan reminder earns its keep
    if MaybePlanReminder then MaybePlanReminder("prompt") end
end

-- ── Sim EVs (Raidbots Droptimizer CSV paste) ────────────────────────────────
-- The report's data.csv is ~20KB of "profileset,dps" lines - small enough
-- to copy straight out of the browser, no converter tool needed. Names
-- encode instanceID/encounterID/source-difficulty/itemID/..., so one paste
-- gives per-item DPS gains keyed exactly like our journal markers.
-- slotless = a tier token / non-equipment journal item
local function IsTokenItem(itemID)
    if not itemID or not C_Item or not C_Item.GetItemInventoryTypeByID then return false end
    local inv = C_Item.GetItemInventoryTypeByID(itemID)
    return inv == (Enum.InventoryType and Enum.InventoryType.IndexNonEquipType or 0)
end

-- The season's OMNI token: the ONE tier token a bonus roll can never grant
-- (Arc-confirmed in-game; the four slot tokens DO roll). Its gain still
-- prices the DROPS surfaces like any token. Update per raid tier.
-- TOKENS HAVE A DIFFERENT ITEM ID PER DIFFICULTY TRACK (live-confirmed:
-- heroic Venomcast Icon 270928 vs the myth-track 268223 a Droptimizer
-- sims). So live journal rows and sim rows NEVER share token ids - the
-- design below is journal-first: the boss's token comes from the journal
-- (right id for the shown difficulty), the sim only prices it.
local OMNI_TOKENS = {
    [271876] = true,   -- Venomous Abyss omni token, myth track (sim id)
    [270909] = true,   -- Venomous Abyss omni token, heroic (live id)
}

-- TokenLab-proven (2026-09-08): the journal reports filterType 14 (Other)
-- for EVERY token - slot tokens, the omni AND per-player items alike - so
-- filterType can NOT identify or slot tokens. What IS reliable: the sim's
-- vault rows carry the GENERATED PIECE directly (Arc's model), and those
-- piece ids match C_LootJournal's set items exactly.
-- Known token slots (Enum.ItemSlotFilterType values), for the old-import
-- fallback where the gain was credited to a sim-side token id:
local TOKEN_SLOTS = {
    [268230] = 0,   -- head token (myth track / sim id)
    [268231] = 2,   -- shoulder token (myth track / sim id)
    [268223] = 4,   -- chest token (myth track / sim id)
    [268238] = 6,   -- hands token (myth track / sim id)
    [270928] = 4,   -- Venomcast Icon: chest token, heroic (live id)
}

-- ── Token -> tier piece, from CLIENT data alone ─────────────────────────────
-- The journal's loot info carries every token's SLOT (filterType), and
-- C_LootJournal lists the spec's tier set pieces by slot - so a token
-- resolves to "the piece it becomes for me" with no sim data at all.
-- db.tokenSlots[tokenID] = filterType, remembered whenever the journal
-- shows a token row (background primer, harvest, or the open guide).
-- (do-block: the caches and slot matcher stay off the main chunk's
-- 200-local budget, which this file is close to)
local TokenPieceFor, TierPieceSet
do
local tokenPieceCache = {}   -- [specID] = { [tokenID] = pieceItemID | false }
local tierPieceCache = {}    -- [classID*1000+specID] = { [itemID] = true }

local function InvMatchesFilter(invType, ft)
    local F, I = Enum.ItemSlotFilterType, Enum.InventoryType
    if not (F and I) then return false end
    if ft == F.Head then return invType == I.IndexHeadType + 1 end
    if ft == F.Shoulder then return invType == I.IndexShoulderType + 1 end
    if ft == F.Chest then
        return invType == I.IndexChestType + 1 or invType == I.IndexRobeType + 1
    end
    if ft == F.Hand then return invType == I.IndexHandType + 1 end
    if ft == F.Legs then return invType == I.IndexLegsType + 1 end
    return false
end

-- every set-piece item id C_LootJournal knows for this class/spec, ALL
-- sets unioned. TokenLab proved (a) these ids match the sim's tier rows
-- EXACTLY, and (b) newest-by-itemLevel picks a non-tier armor set - so
-- membership across every set is the safe test (sims only carry the
-- current raid's pieces anyway).
TierPieceSet = function()
    local classID = select(3, UnitClass("player"))
    local specID = CurrentSpecID()
    if not (classID and specID) then return nil end
    local key = classID * 1000 + specID
    local cached = tierPieceCache[key]
    if cached then return cached end
    if not (C_LootJournal and C_LootJournal.GetItemSets
        and C_LootJournal.GetItemSetItems) then return nil end
    local sets = C_LootJournal.GetItemSets(classID, specID)
    if not sets or #sets == 0 then return nil end     -- data not ready: no cache
    -- TIER-SHAPED sets only: every piece in a tier slot (head, shoulder,
    -- chest/robe, hands, legs). Armor sets carry wrist/waist/feet and must
    -- NOT leak in - their pieces are REGULAR boss drops, and unioning them
    -- re-added pool items as fake token outcomes (Arc's duplicate rows).
    local I = Enum.InventoryType
    local tierInv = I and {
        [I.IndexHeadType + 1] = true, [I.IndexShoulderType + 1] = true,
        [I.IndexChestType + 1] = true, [I.IndexRobeType + 1] = true,
        [I.IndexHandType + 1] = true, [I.IndexLegsType + 1] = true,
    } or nil
    if not tierInv then return nil end
    local out, any = {}, false
    for _i, s in ipairs(sets) do
        local items = C_LootJournal.GetItemSetItems(s.setID) or {}
        local tierShaped = #items > 0
        for _j, it in ipairs(items) do
            if not tierInv[it.invType] then
                tierShaped = false
                break
            end
        end
        if tierShaped then
            for _j, it in ipairs(items) do
                out[it.itemID] = true
                any = true
            end
        end
    end
    if not any then return nil end
    tierPieceCache[key] = out
    return out
end

TokenPieceFor = function(tokenID)
    local specID = CurrentSpecID()
    local ft = TOKEN_SLOTS[tokenID]
    if ft == nil then ft = db and db.tokenSlots and db.tokenSlots[tokenID] end
    if not specID or ft == nil then return nil end
    local perSpec = tokenPieceCache[specID]
    if perSpec and perSpec[tokenID] ~= nil then return perSpec[tokenID] or nil end
    local classID = select(3, UnitClass("player"))
    if not (classID and C_LootJournal and C_LootJournal.GetItemSets
        and C_LootJournal.GetItemSetItems) then return nil end
    local sets = C_LootJournal.GetItemSets(classID, specID)
    if not sets or #sets == 0 then return nil end     -- data not ready: no cache
    -- highest setID with a slot match: set ids grow with releases, and the
    -- TokenLab dump proved itemLevel ranking picks a non-tier armor set
    local piece, bestSet = false, -1
    for _i, s in ipairs(sets) do
        if (s.setID or 0) > bestSet then
            for _j, it in ipairs(C_LootJournal.GetItemSetItems(s.setID) or {}) do
                if InvMatchesFilter(it.invType, ft) then
                    piece, bestSet = it.itemID, s.setID
                    break
                end
            end
        end
    end
    tokenPieceCache[specID] = tokenPieceCache[specID] or {}
    tokenPieceCache[specID][tokenID] = piece
    return piece or nil
end
end

-- THE boss token outcome (Arc's model, TokenLab-proven): the boss's set
-- token becomes ONE specific piece for your class/spec, and the SIM's
-- vault rows already carry that PIECE as a plain gains entry - the
-- journal pool just never lists it (the boss drops the slotless token),
-- which is what kept it out of the roll surfaces. Primary: the best
-- tier-set-piece key in gains (ids match C_LootJournal exactly).
-- Fallback for OLD imports whose parser credited the gain to the sim's
-- token id: map that token to the piece. The omni never rolls (its rows
-- are dropped at parse; old omni-credited entries are skipped here).
-- Returns piece, gain, owned, ownedSource, inGains (piece key present in
-- gains - the no-cache listings already show those as plain rows).
local function GetBossTokenOutcome(enc, simKey, ownedDiff)
    local ev = char and simStore[simKey]
    local gains = ev and ev.gains and ev.gains[enc]
    if not gains then return nil end
    local pieces = TierPieceSet()
    local piece, gain, tokenID
    for id, g in pairs(gains) do
        if pieces and pieces[id] then
            if not gain or g > gain then piece, gain = id, g end
        elseif IsTokenItem(id) and not OMNI_TOKENS[id] then
            tokenID = id
        end
    end
    if not piece and tokenID then
        gain = gains[tokenID]
        piece = TokenPieceFor(tokenID) or tokenID
    end
    if not piece then return nil end
    local owned, source = IsOwnedItem(piece, ownedDiff)
    if not owned and tokenID then owned, source = IsOwnedItem(tokenID, ownedDiff) end
    return piece, gain, owned, source, (gains[piece] ~= nil)
end

-- (do-block: parser constants and helpers stay off the main chunk's
-- 200-local budget)
local ParseDroptimizerCSV, ParseQEReport
do
local DIFF_FROM_SOURCE = { normal = 14, heroic = 15, mythic = 16, lfr = 17 }

ParseDroptimizerCSV = function(text)
    if type(text) ~= "string" or text == "" then return nil end
    local baseline, actorName
    local rows = {}
    for line in text:gmatch("[^\r\n]+") do
        local name, mean = line:match("^([^,]+),([%d%.]+)")
        local meanN = mean and tonumber(mean) or nil
        if name and meanN then
            if not name:find("/") then
                -- the first non-profileset numeric row is the baseline
                -- actor - its NAME is the simmed character
                if not baseline then
                    baseline = meanN
                    actorName = name
                end
            else
                local f = {}
                for part in (name .. "/"):gmatch("([^/]*)/") do f[#f + 1] = part end
                local src = f[3] or ""
                if src:find("raid") then
                    local diff
                    for word, id in pairs(DIFF_FROM_SOURCE) do
                        if src:find(word) then diff = id break end
                    end
                    -- a trailing item field means the simmed piece is a
                    -- CONVERSION (tier token / catalyst) of that DROP:
                    -- credit the gain to the item that actually drops,
                    -- so the journal row shows its best use
                    local enc = tonumber(f[2])
                    local tokenID = tonumber(f[11])
                    local isVault = src:find("vault") ~= nil
                    -- "raid-vault-*" rows are the BONUS ROLL track and get
                    -- their own bucket. VAULT conversion rows keep the
                    -- GENERATED PIECE as the key (Arc's model: the coin
                    -- grants the piece; the piece ids match C_LootJournal),
                    -- and omni conversions are dropped - the omni never
                    -- rolls. DROPS rows keep crediting the token: the
                    -- guide's token row is what gets priced there.
                    local item
                    if isVault then
                        -- (plain if, NOT `and nil or`: that idiom always
                        -- falls through to the or-branch)
                        if tokenID and OMNI_TOKENS[tokenID] then
                            -- omni conversion: the omni never rolls
                        elseif tokenID and not IsTokenItem(tokenID) then
                            -- CATALYST conversion of a REAL drop (the source
                            -- has an equip slot): the coin grants the SOURCE
                            -- item, catalyzing is the player's later choice -
                            -- credit the source so one drop is ONE row at its
                            -- best use (Arc's Soulslither/Hissing Mantle
                            -- double-count)
                            item = tokenID
                        else
                            -- true slotless TOKEN (or a plain row): the coin
                            -- grants token -> piece; key the piece
                            item = tonumber(f[4])
                        end
                    else
                        item = tokenID or tonumber(f[4])
                    end
                    if diff and enc and item then
                        local key = isVault and ("vault" .. diff) or diff
                        -- when the credited item differs from the simmed
                        -- piece, this row is a CONVERSION - remember what
                        -- the drop becomes (catalyst piece / token piece)
                        local simmed = tonumber(f[4])
                        rows[#rows + 1] = { diff = key, enc = enc, item = item, mean = meanN,
                                            lv = tonumber(f[5]),
                                            conv = (simmed and simmed ~= item) and simmed or nil }
                    end
                elseif src:find("dungeon") then
                    local diff = src:find("weekly") and "mplusBonus" or "mplus"
                    -- bonus-roll rows DO carry the dungeon (journal instance
                    -- in slot 2), and the M+ bonus roll pool is all of a
                    -- dungeon's bosses in ONE pool - so key those per
                    -- dungeon. Run rows carry nothing there: pooled under -1.
                    local enc = (diff == "mplusBonus") and tonumber(f[2]) or nil
                    if not enc or enc <= 0 then enc = -1 end
                    local item = tonumber(f[11]) or tonumber(f[4])
                    if item then
                        local simmed = tonumber(f[4])
                        rows[#rows + 1] = { diff = diff, enc = enc, item = item, mean = meanN,
                                            lv = tonumber(f[5]),
                                            conv = (simmed and simmed ~= item) and simmed or nil }
                    end
                end
            end
        end
    end
    if not baseline or #rows == 0 then return nil end
    -- an item can be simmed several ways (trinket1/trinket2, ring slots,
    -- tier pairings): keep the BEST gain per (difficulty, boss, item).
    -- The SIMMED ITEM LEVEL rides along per bucket (highest wins): the
    -- tooltip says what level the sim actually priced, since a bare
    -- itemID tooltip can only preview the base version.
    local out, lvOut, convOut, plainOut = {}, {}, {}, {}
    for _, r in ipairs(rows) do
        local gain = r.mean - baseline
        out[r.diff] = out[r.diff] or {}
        out[r.diff][r.enc] = out[r.diff][r.enc] or {}
        local cur = out[r.diff][r.enc][r.item]
        if not cur or gain > cur then
            out[r.diff][r.enc][r.item] = gain
            -- the WINNING row decides the story: a conversion row winning
            -- means "this drop is best used as <piece>"; an as-is row
            -- winning clears it
            convOut[r.diff] = convOut[r.diff] or {}
            convOut[r.diff][r.item] = r.conv or nil
        end
        -- keep the best AS-DROPPED gain separately: when the catalyzed
        -- use wins, the tooltip shows both numbers side by side
        if not r.conv then
            plainOut[r.diff] = plainOut[r.diff] or {}
            local cp = plainOut[r.diff][r.item]
            if not cp or gain > cp then plainOut[r.diff][r.item] = gain end
        end
        if r.lv then
            lvOut[r.diff] = lvOut[r.diff] or {}
            local clv = lvOut[r.diff][r.item]
            if not clv or r.lv > clv then lvOut[r.diff][r.item] = r.lv end
        end
    end
    return baseline, out, lvOut, actorName, convOut, plainOut
end

-- ── QE Live upgrade report paste (healers) ──────────────────────────────────
-- questionablyepic.com/live/upgradereport/<id> has a public raw endpoint:
--   https://questionablyepic.com/api/getUpgradeReport.php?reportID=<id>
-- The JSON is double-encoded, and entries carry NO boss ids (QE resolves
-- those client-side) - bosses are attributed through OUR pool caches.
-- Entry shape (verified against two live reports):
--   {"item":268196,"dropLoc":"Raid","dropType":"bonus","dropDifficulty":2,
--    "level":334,...,"rawDiff":1043,"percDiff":0.298}
--   dropLoc  Raid | Dungeon | Crafted | Delves
--   dropType drop (base track) | max (6/6 projection, skipped) | bonus
--   dropDifficulty (raid) = QE's own enum, 0 LFR / 1 Normal / 2 Heroic /
--   3 Mythic (their source: ["Raid Finder","Normal","Heroic","Mythic"]);
--   for dungeons it is the M+ key level.
-- Gains = percDiff -> percent-native buckets, like the WoWUtils QE path.
local QE_RAID_DIFF = { [0] = 17, [1] = 14, [2] = 15, [3] = 16 }

ParseQEReport = function(text)
    if type(text) ~= "string" then return nil end
    if not (text:find("dropLoc") and text:find("percDiff")) then return nil end
    local s = text:gsub('\\"', '"')   -- the raw endpoint serves it double-encoded
    -- report identity: QE stamps the owner's spec and name in the header
    local repSpec = s:match('"spec":"([^"]+)"')
    local repPlayer = s:match('"playername":"([^"]+)"')
    local buckets = {}
    local lvs = {}
    local placed = 0
    local entryLv
    local function put(diffKey, enc, itemID, perc)
        buckets[diffKey] = buckets[diffKey] or {}
        buckets[diffKey][enc] = buckets[diffKey][enc] or {}
        local cur = buckets[diffKey][enc][itemID]
        if not cur or perc > cur then buckets[diffKey][enc][itemID] = perc end
        if entryLv then
            lvs[diffKey] = lvs[diffKey] or {}
            local clv = lvs[diffKey][itemID]
            if not clv or entryLv > clv then lvs[diffKey][itemID] = entryLv end
        end
        placed = placed + 1
    end
    for entry in s:gmatch("%{(.-)%}") do
        local itemID = tonumber(entry:match('"item":(%d+)'))
        local loc = entry:match('"dropLoc":"(%a+)"')
        local typ = entry:match('"dropType":"(%a+)"')
        local dd = tonumber(entry:match('"dropDifficulty":(%d+)') or "")
        local perc = tonumber(entry:match('"percDiff":([%-%d%.eE]+)') or "")
        entryLv = tonumber(entry:match('"level":(%d+)') or "")
        if itemID and loc and typ and perc then
            if loc == "Raid" and (typ == "drop" or typ == "bonus") and QE_RAID_DIFF[dd] then
                local diff = QE_RAID_DIFF[dd]
                -- boss attribution through the journal pool cache (the
                -- background primer keeps it filled); items the pool does
                -- not know - tokens included - are skipped
                local enc
                local pools = poolStore[diff]
                if pools then
                    for e, set in pairs(pools) do
                        if set[itemID] then enc = e break end
                    end
                end
                if enc then
                    put(typ == "bonus" and ("vault" .. diff) or diff, enc, itemID, perc)
                end
            elseif loc == "Dungeon" and typ == "drop" then
                put("mplus", -1, itemID, perc)
            elseif loc == "Dungeon" and typ == "bonus" then
                local inst
                if poolStore.mplusBonus then
                    for id, set in pairs(poolStore.mplusBonus) do
                        if set[itemID] then inst = id break end
                    end
                end
                if inst then put("mplusBonus", inst, itemID, perc) end
            end
            -- "max" rows (6/6 projections) and Crafted/Delves are not drops
        end
    end
    if placed == 0 then return nil end
    return buckets, lvs, repSpec, repPlayer
end
end

-- QE reports stamp the owner's spec ("Restoration Druid"). Resolve that
-- string against the client's own class/spec roster - the class token
-- disambiguates the two Restorations. Localized names, so a non-matching
-- locale simply resolves nothing and stays permissive.
local function ResolveSpecFromQEString(str)
    if type(str) ~= "string" or str == "" then return nil end
    local needle = str:lower()
    local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
        or GetNumSpecializationsForClassID
    local getInfo = GetSpecializationInfoForClassID
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
    if not (getNum and getInfo) then return nil end
    for classID = 1, (GetNumClasses and GetNumClasses() or 13) do
        local ci = C_CreatureInfo and C_CreatureInfo.GetClassInfo
            and C_CreatureInfo.GetClassInfo(classID)
        local className = ci and ci.className
        if className and needle:find(className:lower(), 1, true) then
            for i = 1, getNum(classID) or 0 do
                local id, name = getInfo(classID, i)
                if id and name and needle:find(name:lower(), 1, true) then
                    return id
                end
            end
        end
    end
    return nil
end

-- The seed's per-spec loot sets double as a SPEC FINGERPRINT: a
-- Droptimizer CSV carries no spec identity, but its item list IS the
-- spec's eligible loot - overlapping it against each seed spec of the
-- class identifies which spec was simmed. Confident only on a strict
-- lead, so near-identical loot lists (ele vs resto) resolve to nil and
-- fall back to the chosen target instead of guessing.
local specSeedSets
local function SeedSetFor(specID)
    local seed = NS.PoolSeed
    local sp = seed and seed.specs and seed.specs[specID]
    if not sp then return nil end
    specSeedSets = specSeedSets or {}
    local set = specSeedSets[specID]
    if set then return set end
    set = {}
    for _, encs in pairs(sp.r or {}) do
        for _, ids in pairs(encs) do
            for id in ids:gmatch("%d+") do set[tonumber(id)] = true end
        end
    end
    for _, ids in pairs(sp.d or {}) do
        for id in ids:gmatch("%d+") do set[tonumber(id)] = true end
    end
    specSeedSets[specID] = set
    return set
end

local function DetectSpecFromSimItems(byDiff, classID)
    if not (classID and NS.PoolSeed and byDiff) then return nil end
    local items = {}
    for _, encs in pairs(byDiff) do
        for _, gains in pairs(encs) do
            for itemID in pairs(gains) do items[itemID] = true end
        end
    end
    local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
        or GetNumSpecializationsForClassID
    local getInfo = GetSpecializationInfoForClassID
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
    if not (getNum and getInfo) then return nil end
    local best, bestHits, secondHits
    for i = 1, getNum(classID) or 0 do
        local specID = getInfo(classID, i)
        local set = specID and SeedSetFor(specID)
        if set then
            local hits = 0
            for itemID in pairs(items) do
                if set[itemID] then hits = hits + 1 end
            end
            if not bestHits or hits > bestHits then
                secondHits = bestHits
                best, bestHits = specID, hits
            elseif not secondHits or hits > secondHits then
                secondHits = hits
            end
        end
    end
    if best and bestHits >= 8 and bestHits > (secondHits or 0) then
        return best
    end
    return nil
end

-- returns: importedDiffCount, itemCount, err, usedSpec. The sim decides
-- where it lands: a sim for another CHARACTER is refused by name; a sim
-- for another SPEC of this character is routed into that spec's bucket
-- (CSV: seed fingerprint; QE: the report's own spec stamp).
local function ApplySimImport(text, bucket, targetSpec, targetName, targetClassID, bucketForSpec)
    if not storesLinked then RelinkSpecStores() end
    if not char then return nil end
    bucket = bucket or simStore
    local baseline, byDiff, byLv, actorName, byConv, byPlain = ParseDroptimizerCSV(text)
    if not baseline then
        -- QE Live upgrade report (healers): percent-native buckets
        local qe, qeLv, repSpec, repPlayer = ParseQEReport(text)
        if qe then
            -- another character's report poisons the buckets - refuse
            if repPlayer and targetName and repPlayer:lower() ~= targetName:lower() then
                return nil, nil, ("This QE report belongs to %s (%s) - not to %s. Import it on that character."):format(
                    repPlayer, repSpec or "?", targetName)
            end
            -- same character, another spec: the report says which - route it
            local usedSpec = targetSpec
            local repID = ResolveSpecFromQEString(repSpec)
            if repID and targetSpec and repID ~= targetSpec and bucketForSpec then
                bucket = bucketForSpec(repID)
                usedSpec = repID
            end
            local diffs, items = 0, 0
            for diff, gains in pairs(qe) do
                bucket[diff] = { base = nil, t = time(), gains = gains, pct = true,
                                 lv = qeLv and qeLv[diff] or nil }
                diffs = diffs + 1
                for _, eg in pairs(gains) do
                    for _ in pairs(eg) do items = items + 1 end
                end
            end
            return diffs, items, nil, usedSpec
        end
        return nil
    end
    if actorName and targetName and actorName:lower() ~= targetName:lower() then
        return nil, nil, ("This sim is for %s - not for %s. Import it on that character."):format(
            actorName, targetName)
    end
    local usedSpec = targetSpec
    local det = DetectSpecFromSimItems(byDiff, targetClassID)
    if det and targetSpec and det ~= targetSpec and bucketForSpec then
        bucket = bucketForSpec(det)
        usedSpec = det
    end
    local diffs, items = 0, 0
    for diff, gains in pairs(byDiff) do
        bucket[diff] = { base = baseline, t = time(), gains = gains,
                         lv = byLv and byLv[diff] or nil,
                         cv = byConv and byConv[diff] or nil,
                         ca = byPlain and byPlain[diff] or nil }
        diffs = diffs + 1
        for _, encGains in pairs(gains) do
            for _ in pairs(encGains) do items = items + 1 end
        end
    end
    return diffs, items, nil, usedSpec
end

-- ZERO-PASTE import from the WoWUtils companion addon: it stores fully
-- parsed droptimizer data in its SavedVariables -
--   WowUtilsDB.droptimizerData["<name lower>-<realmId>"]
--     .specs[specId][simId] = { items, baseline, simmedAt }
--   items[itemId] = array of { difficultyId (14/15/16, same journal IDs
--   we use), gain (already baseline-relative), encounterId (journal;
--   negative = non-raid), sourceItem { itemId, encounterId } when the
--   piece comes from converting a DROP (tier token / catalyst) }.
-- Rows read from another addon's DB are data, never trusted blindly:
-- every field is type-guarded. Newest sim per difficulty wins.
local function ImportFromWowUtils()
    if not char then return nil, "not ready" end
    if not storesLinked then RelinkSpecStores() end
    local db = _G.WowUtilsDB
    local data = db and db.droptimizerData
    if type(data) ~= "table" then
        return nil, "WoWUtils addon (or its droptimizer data) not found."
    end
    local rec
    local myName = (UnitName("player") or ""):lower()
    local realmId = GetRealmID and GetRealmID() or nil
    if realmId then rec = data[myName .. "-" .. tostring(realmId)] end
    if not rec then
        for _, d in pairs(data) do
            if type(d) == "table" and type(d.characterName) == "string"
                and d.characterName:lower() == myName then
                rec = d
                break
            end
        end
    end
    if not (rec and type(rec.specs) == "table") then
        return nil, "WoWUtils has no droptimizer data for this character."
    end
    local specIndex = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        and C_SpecializationInfo.GetSpecialization() or nil
    local specId = specIndex and C_SpecializationInfo.GetSpecializationInfo(specIndex) or nil
    local sims = specId and rec.specs[specId] or nil
    if not sims then
        return nil, "WoWUtils has no sims stored for your current spec."
    end
    -- pick the newest sim per difficulty. Two sim types live here:
    -- raidbots (absolute gains + baseline) and QE LIVE (healers: percent
    -- gains in gainPercent, NO baseline - simType 2 in WoWUtils' enum).
    local newest = {}
    for _, sim in pairs(sims) do
        if type(sim) == "table" and type(sim.items) == "table"
            and (type(sim.baseline) == "number" or sim.simType == 2) then
            local diffsIn = {}
            for _, entries in pairs(sim.items) do
                if type(entries) == "table" then
                    for _, e in ipairs(entries) do
                        local enc = (type(e.sourceItem) == "table" and e.sourceItem.encounterId) or e.encounterId
                        if type(enc) == "number" and enc > 0 and type(e.difficultyId) == "number" then
                            diffsIn[e.difficultyId] = true
                        end
                    end
                end
            end
            for d in pairs(diffsIn) do
                if not newest[d] or (sim.simmedAt or 0) > (newest[d].simmedAt or 0) then
                    newest[d] = sim
                end
            end
        end
    end
    local diffs, items = 0, 0
    for d, sim in pairs(newest) do
        local gains = {}
        local lvs = {}
        for itemId, entries in pairs(sim.items) do
            if type(entries) == "table" then
                for _, e in ipairs(entries) do
                    -- raidbots entries carry `gain` (absolute DPS), QE Live
                    -- entries carry `gainPercent` (healers) - accept either
                    local g = (type(e.gain) == "number" and e.gain)
                        or (type(e.gainPercent) == "number" and e.gainPercent) or nil
                    if e.difficultyId == d and g then
                        local src = type(e.sourceItem) == "table" and e.sourceItem or nil
                        local enc = (src and src.encounterId) or e.encounterId
                        local dropItem = (src and src.itemId) or itemId
                        if type(enc) == "number" and enc > 0 and type(dropItem) == "number" then
                            gains[enc] = gains[enc] or {}
                            local cur = gains[enc][dropItem]
                            if not cur or g > cur then gains[enc][dropItem] = g end
                            -- field name varies by WoWUtils version; all guarded
                            local elv = (type(e.itemLevel) == "number" and e.itemLevel)
                                or (type(e.level) == "number" and e.level)
                                or (type(e.ilvl) == "number" and e.ilvl) or nil
                            if elv then
                                local clv = lvs[dropItem]
                                if not clv or elv > clv then lvs[dropItem] = elv end
                            end
                        end
                    end
                end
            end
        end
        if next(gains) then
            -- QE Live buckets are percent-native: flag them so every
            -- readout formats "+1.2%" (there is no raw DPS to show)
            local isPct = (sim.simType == 2) or type(sim.baseline) ~= "number"
            simStore[d] = { base = type(sim.baseline) == "number" and sim.baseline or nil,
                            t = sim.simmedAt or time(), gains = gains, pct = isPct or nil,
                            lv = next(lvs) and lvs or nil }
            diffs = diffs + 1
            for _, eg in pairs(gains) do
                for _ in pairs(eg) do items = items + 1 end
            end
        end
    end
    if diffs == 0 then
        return nil, "WoWUtils data held no usable raid gains."
    end
    return diffs, items
end

-- NO auto-import from WoWUtils. It ran at login and on spec swap when the
-- spec's bucket was empty, and its "empty" check could not tell "the user
-- never imported" from "the user's manual import went to another bucket"
-- - it overwrote Arc's manual paste. WoWUtils data now arrives ONLY from
-- the explicit "Import from WoWUtils" button (Arc's call, 2026-09-06).

local function SimGainFor(diff, enc, itemID)
    local ev = char and simStore[diff]
    local g = ev and ev.gains[enc]
    return g and g[itemID] or nil
end

-- Set/tier TOKENS: the journal lists the token, but the Droptimizer often
-- prices only the RESULTING piece with no source reference (class-generic
-- "Use: create a set item" tokens). A simmed item at a boss that is NOT in
-- the boss's visible pool is by definition such a conversion result - its
-- best gain is the token's value. (IsTokenItem lives above the parser now.)
local function OrphanTokenGain(diff, enc, poolDiff, ownedDiff)
    local ev = char and simStore[diff]
    local gains = ev and ev.gains[enc]
    if not gains then return nil end
    local pool = poolStore[poolDiff or diff] and poolStore[poolDiff or diff][enc]
    if not (pool and next(pool)) then return nil end
    local best
    for itemID, g in pairs(gains) do
        if pool[itemID] == nil and not IsOwnedItem(itemID, ownedDiff or diff)
            and (not best or g > best) then
            best = g
        end
    end
    return best
end

-- direct gain, else the token fallback (non-equipment journal items only).
-- poolDiff: the journal-pool bucket when the sim bucket is a vault one.
local function ItemGainFor(diff, enc, itemID, poolDiff, ownedDiff)
    local g = SimGainFor(diff, enc, itemID)
    if g == nil and IsTokenItem(itemID) then
        g = OrphanTokenGain(diff, enc, poolDiff, ownedDiff)
    end
    return g
end

-- THE one authority for a boss's roll EV: computed from the sim data
-- alone (sum of un-collected positive gains / count of un-collected sim
-- items). Never from the journal's shown list - the two disagree (tier
-- rows carry token itemIDs while sims carry the resulting pieces), which
-- made a boss's EV change depending on which page was open.
local function BossSimEV(enc, diff, ownedDiff, poolDiff)
    -- ownedDiff: the marks/won bucket when it differs from the sim bucket
    -- (M+ dungeons: sims under "mplusBonus", ownership under MPLUS_DIFF).
    -- poolDiff: the journal-pool bucket (vault sim buckets have no pools of
    -- their own - the coin draws from the REAL difficulty's loot table).
    ownedDiff = ownedDiff or diff
    poolDiff = poolDiff or diff
    local ev = char and simStore[diff]
    local gains = ev and ev.gains[enc]
    if not gains then return nil end
    -- with a cached journal pool, intersect: only items the boss actually
    -- drops count as outcomes (sim-only phantoms are excluded); a pool
    -- item the sim did not value contributes 0 but still dilutes
    local cache = poolStore[poolDiff] and poolStore[poolDiff][enc]
    local hadCache = cache and next(cache) ~= nil
    local sum, remaining = 0, 0
    if hadCache then
        for itemID in pairs(cache) do
            if not IsOwnedItem(itemID, ownedDiff) then
                remaining = remaining + 1
                local g = gains[itemID]
                if g and g > 0 then sum = sum + g end
            end
        end
    else
        for itemID, g in pairs(gains) do
            -- token-credited entries are handled once below as the boss
            -- token outcome; the omni never rolls at all
            if not IsTokenItem(itemID) then
                if not IsOwnedItem(itemID, ownedDiff) then
                    remaining = remaining + 1
                    if g > 0 then sum = sum + g end
                end
            end
        end
    end
    -- THE BOSS TOKEN outcome joins the pool (Arc's correction): the tier
    -- piece the coin can grant, which the journal pool never lists. In
    -- the no-cache branch a piece-keyed entry was already counted above.
    local piece, tGain, tOwned, _src, inGains = GetBossTokenOutcome(enc, diff, ownedDiff)
    -- never double-count: a piece that IS a pool item (or already counted
    -- from gains in the no-cache branch) is not an extra outcome
    if piece and not tOwned
        and ((hadCache and not cache[piece]) or (not hadCache and not inGains)) then
        remaining = remaining + 1
        if tGain and tGain > 0 then sum = sum + tGain end
    end
    if remaining > 0 and sum > 0 then
        return sum / remaining, remaining
    end
    return nil
end

-- Bonus-roll surfaces prefer the BONUS TRACK sim ("vaultN" bucket, from a
-- raid-vault Droptimizer) and fall back to the drop sim when none exists.
-- Drops surfaces always read the plain numeric bucket.
local function RollSimKey(diff)
    if type(diff) == "number" and simStore["vault" .. diff] then
        return "vault" .. diff
    end
    return diff
end

local function SimBaseFor(diff)
    local ev = char and simStore[diff]
    return ev and ev.base or nil
end

-- "+3,478" or, in percent mode, "+1.9%" (Raidbots' Relative DPS view)
local function FormatGainNumber(v, diff)
    -- QE Live buckets (healers) are percent-native: always show percent,
    -- there is no raw DPS number behind them
    local ev = char and simStore[diff]
    if ev and ev.pct then
        return ("%+.1f%%"):format(v)
    end
    if char and char.settings.evPercent then
        local base = SimBaseFor(diff)
        if base and base > 0 then
            return ("%+.1f%%"):format(v / base * 100)
        end
    end
    local sign = v >= 0 and "+" or "-"
    return sign .. BreakUpLargeNumbers(math.floor(math.abs(v) + 0.5))
end

-- ── Loot pool (estimated share per un-collected item) ───────────────────────
-- Pool = the loot list as the journal currently filters it (class/spec/slot/
-- difficulty), grouped per boss, per-player Bonus Loot excluded (separate
-- mechanic, not part of the roll table). Owned items (won or checked off)
-- shrink the pool. Estimated share = 1 / remaining, and it is clearly labeled
-- an estimate: the roll's gold-vs-loot rate is server-side and unknowable.
local lootPool

WipeLootPool = function()
    lootPool = nil
end

-- M+ mode: on DUNGEON journal pages every overlay is the Mythic+ bonus
-- roll layer - one pool for the whole dungeon - regardless of which
-- dungeon difficulty the journal is showing.
local function EJDungeonMode()
    return (EncounterJournal and EncounterJournal:IsShown()
        and EJ_InstanceIsRaid and not EJ_InstanceIsRaid()) and true or false
end

local function EJCurrentInstanceID()
    return EncounterJournal and EncounterJournal.instanceID or nil
end

local function EnsureLootPool()
    if lootPool then return end
    do
        lootPool = {}
        local dungeonMode = EJDungeonMode()
        local instID = dungeonMode and EJCurrentInstanceID() or nil
        local diffNow = (EJ_GetDifficulty and EJ_GetDifficulty()) or 0
        -- ownership in M+ mode lives under the canonical keystone key
        local ownDiff = dungeonMode and MPLUS_DIFF or diffNow
        -- record the journal pool only when the view is trustworthy: the
        -- player's own class and no slot filter (a narrowed or foreign
        -- view must never overwrite the cached truth)
        local canCache = char ~= nil and diffNow ~= 0
        if canCache and EJ_GetLootFilter then
            -- the pool bucket is per SPEC (account-wide): only a view
            -- filtered to exactly the player's current spec may write it
            local cls, spec = EJ_GetLootFilter()
            if cls ~= select(3, UnitClass("player")) then canCache = false end
            local mySpec = CurrentSpecID()
            if not mySpec or (spec or 0) ~= mySpec then canCache = false end
        end
        if canCache and C_EncounterJournal.GetSlotFilter and Enum and Enum.ItemSlotFilterType then
            local sf = C_EncounterJournal.GetSlotFilter()
            if sf and sf ~= Enum.ItemSlotFilterType.NoFilter then canCache = false end
        end
        local fresh = canCache and {} or nil
        local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
        for i = 1, n do
            local info = C_EncounterJournal.GetLootInfoByIndex(i)
            -- pool = EQUIPMENT only: the Voidcore "transmutes into powerful
            -- equipment", so per-player Bonus Loot rows and slotless items
            -- (mounts, curios, quest pieces) are not part of the roll table
            if info and info.encounterID and not info.displayAsPerPlayerLoot
                and info.slot and info.slot ~= "" then
                local pool = lootPool[info.encounterID]
                if not pool then
                    pool = { total = 0, owned = 0, gainSum = 0 }
                    lootPool[info.encounterID] = pool
                end
                pool.total = pool.total + 1
                if info.itemID and fresh then
                    fresh[info.encounterID] = fresh[info.encounterID] or {}
                    -- link, not just true: tooltips + the gear scan need it
                    fresh[info.encounterID][info.itemID] = info.link or true
                end
                if info.itemID and IsOwnedItem(info.itemID, ownDiff) then
                    pool.owned = pool.owned + 1
                elseif info.itemID then
                    -- un-collected: its sim gain feeds the boss's EV. M+
                    -- gains live in the per-dungeon "mplusBonus" bucket.
                    local gain
                    if dungeonMode then
                        gain = instID and SimGainFor("mplusBonus", instID, info.itemID) or nil
                    else
                        gain = SimGainFor(diffNow, info.encounterID, info.itemID)
                    end
                    if gain and gain > 0 then
                        pool.gainSum = pool.gainSum + gain
                    end
                end
            end
        end
        if fresh then
            if dungeonMode then
                -- dungeon pages list the whole dungeon's loot - but the loot
                -- list can BRIEFLY still hold another page's items while an
                -- instance switch streams in, and the Keystone aggregate
                -- page lists EVERY season dungeon at once. A blind merge
                -- accumulated all of that forever. So: validate every item
                -- against THIS dungeon's own boss list, REPLACE the pool on
                -- a full-dungeon view (self-heals old pollution), and only
                -- merge from single-boss (partial) views.
                if instID and instID ~= MPLUS_AGGREGATE_INSTANCE and next(fresh) then
                    local valid = {}
                    local vi = 1
                    while true do
                        local _, _, bossID = EJ_GetEncounterInfoByIndex(vi, instID)
                        if not bossID then break end
                        valid[bossID] = true
                        vi = vi + 1
                    end
                    if next(valid) then
                        local vetted = {}
                        for enc, set in pairs(fresh) do
                            if valid[enc] then
                                for itemID, v in pairs(set) do vetted[itemID] = v end
                            end
                        end
                        if next(vetted) then
                            poolStore.mplusBonus = poolStore.mplusBonus or {}
                            local fullView = not (EncounterJournal and EncounterJournal.encounterID)
                            local union = (not fullView) and (poolStore.mplusBonus[instID] or {}) or {}
                            for itemID, v in pairs(vetted) do
                                -- keep a link once we have one; never downgrade
                                if type(v) == "string" or not union[itemID] then
                                    union[itemID] = v
                                end
                            end
                            poolStore.mplusBonus[instID] = union
                        end
                    end
                end
            else
                -- CURRENT-raid pages only, raid difficulties only: browsing
                -- an old raid (or an oddball difficulty) must never write
                -- into the season pools - that is exactly how Kings' Rest
                -- bosses and a difficulty-2 bucket ended up inside them
                local viewInst = EJCurrentInstanceID()
                if viewInst and db and viewInst == db.currentRaidInst
                    and (diffNow == 14 or diffNow == 15 or diffNow == 16 or diffNow == 17) then
                    for enc, set in pairs(fresh) do
                        -- only replace a boss's cached pool with a COMPLETE
                        -- view of it (the list always carries a boss's full
                        -- table when the boss is present at all)
                        poolStore[diffNow] = poolStore[diffNow] or {}
                        poolStore[diffNow][enc] = set
                    end
                end
            end
        end
    end
end

local function GetEncounterPool(encID)
    if not encID then return nil end
    EnsureLootPool()
    return lootPool[encID]
end

-- the whole-dungeon pool: every boss's rollable loot summed - the M+
-- bonus roll draws from all of it at once
local function GetDungeonPool()
    EnsureLootPool()
    local agg = { total = 0, owned = 0 }
    for _, pool in pairs(lootPool) do
        agg.total = agg.total + pool.total
        agg.owned = agg.owned + pool.owned
    end
    return agg.total > 0 and agg or nil
end

-- ── Adventure Guide markers ─────────────────────────────────────────────────
local bossMarkers = {}   -- [bossButton] = marker
local itemMarkers = {}   -- [itemButton] = marker

-- icon split (Arc's call): the LOOT BAG tags drop-EV lines in the
-- Adventure Guide; the ALP BADGE is the loot roll window's mark ONLY
local LOOT_EV_ICON = "Interface\\GroupFrame\\UI-Group-MasterLooter"
-- the glowing chest logo (glow-keyed alpha; media\arc is the older ALP disc)
local ROLL_BADGE_ICON = "Interface\\AddOns\\ArcUI\\Bonus_Roll\\media\\arc_chest"

local function CurrentEJDifficulty()
    local diff = EJ_GetDifficulty and EJ_GetDifficulty() or 0
    return diff or 0
end

-- Would ANY auto rule re-check this boss the moment its done-flag clears?
-- Un-checking must store FALSE exactly when this is true, so the player's
-- override ALWAYS sticks even where the addon's auto-check is wrong. The
-- old per-site guesses each saw only one source (live journal list here,
-- same-refresh state there) and could store nil - auto then silently
-- re-checked the boss from the source they did not look at.
local function AutoWouldCheck(enc, diff)
    -- confirmed pool fully collected (persisted cache, works everywhere)
    local pool = poolStore[diff] and poolStore[diff][enc]
    if pool and next(pool) then
        local left = 0
        for itemID in pairs(pool) do
            if not IsOwnedItem(itemID, diff) then left = left + 1 end
        end
        if left == 0 then return true end
    end
    -- live journal loot list (session view of the same rule)
    local live = GetEncounterPool(enc)
    if live and live.total > 0 and live.owned >= live.total then return true end
    -- sim list fully owned (the Overview's sim-based auto rule)
    local ev = simStore[diff]
    local gains = ev and ev.gains[enc]
    if gains and next(gains) then
        local anyLeft = false
        for itemID in pairs(gains) do
            if not IsOwnedItem(itemID, diff) then anyLeft = true break end
        end
        if not anyLeft then return true end
    end
    return false
end

-- Which journal content shows our overlays: bonus rolls are a RAID system,
-- so raid pages are on by default and dungeon/M+ pages are opt-in.
local function EJViewAllowed()
    if not ModuleEnabled() then return false end
    local isRaid = EJ_InstanceIsRaid and EJ_InstanceIsRaid() or false
    if isRaid then return char.settings.showOnRaids ~= false end
    return char.settings.showOnDungeons == true
end

-- BOSS rows: the planned-boss picker. Coin = click to save your coin for
-- this boss this week; star = planned; small check badge = rolled this week.
local function BossMarkerUpdate(m)
    local btn = m:GetParent()
    local enc = btn and btn.encounterID
    if not char or not enc or not char.settings.ejOverlay or not EJViewAllowed()
        or char.settings.showShares == false then
        m:Hide()
        return
    end
    -- M+ plans are per DUNGEON (one pool, all bosses): the dungeon page's
    -- title coin owns planning there; boss rows carry no coins
    if EJDungeonMode() then
        m:Hide()
        return
    end
    m:Show()
    local week = CurrentWeek()
    local diff = CurrentEJDifficulty()
    local rec = GetRollRecord(week, enc, diff)
    local planned = IsPlanned(week, enc, diff)
    -- done = manually checked off, or the whole pool is collected (auto,
    -- only computable while this boss's loot is in the journal's list).
    -- An explicit FALSE suppresses auto-done: the player un-checked a
    -- fully-collected boss and that choice must stick.
    local doneFlag = char.doneBosses[BossKey(enc, diff)]
    local doneManual = doneFlag == true
    local doneAuto = false
    if doneFlag == nil then
        local pool = GetEncounterPool(enc)
        doneAuto = (pool and pool.total > 0 and pool.owned >= pool.total) and true or false
    end
    m.state = { enc = enc, diff = diff, week = week, rec = rec, planned = planned,
                done = doneManual or doneAuto, doneManual = doneManual }
    if m.state.done then
        -- done = the Voidcore at FULL COLOR with a big green check on top
        -- (Arc's design: reads as "this bonus roll is finished")
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(false)
        m:SetAlpha(1)
        m.badge:Hide()
        m.planRing:Hide()
        m.doneCheck:Show()
        return
    end
    m.doneCheck:Hide()
    -- same Voidcore icon in both states, always SOLID: desaturated = not
    -- picked, full color = on this week's bonus roll list (Arc's design)
    m.icon:SetTexture(CoinIconTexture())
    m.icon:SetDesaturated(not planned)
    m.planRing:SetShown(planned)
    m:SetAlpha(1)
    m.badge:SetShown(rec ~= nil)
    -- sim EV per coin: expected DPS gain of rolling this boss right now,
    -- ALWAYS from BossSimEV so the number is identical on every page.
    -- Bonus-roll surface: the vault-track sim wins when imported.
    local simKey = RollSimKey(diff)
    local evValue = BossSimEV(enc, simKey, diff, diff)
    m.ev:SetText(evValue and FormatGainNumber(evValue, simKey) or "")
end

local function BossMarkerClick(m, mouseButton)
    if not char or not m.state then return end
    local s = m.state
    if mouseButton == "RightButton" then
        -- check off / un-check this boss (this difficulty). Un-checking
        -- stores FALSE whenever any auto rule would re-check it, so the
        -- player's override sticks; nil (clean DB) otherwise.
        local key = BossKey(s.enc, s.diff)
        if s.done then
            char.doneBosses[key] = AutoWouldCheck(s.enc, s.diff) and false or nil
        else
            char.doneBosses[key] = true
        end
    else
        if s.done then return end   -- finished bosses are not plannable
        local key = BossKey(s.enc, s.diff)   -- plans are PER DIFFICULTY
        local p = char.plan[s.week]
        if p and p[key] then
            p[key] = nil
            if not next(p) then char.plan[s.week] = nil end
        else
            char.plan[s.week] = p or {}
            char.plan[s.week][key] = true
        end
    end
    RefreshEJ()
    UpdateCovers()
    if RefreshWindow then RefreshWindow() end
end

local function BossMarkerEnter(m)
    if not m.state then return end
    local s = m.state
    GameTooltip:SetOwner(m, "ANCHOR_RIGHT")
    GameTooltip:SetText("Arc Loot Planner", 0.2, 0.8, 1)
    local diff = DifficultyName(s.diff)
    if s.done then
        GameTooltip:AddLine(s.doneManual
            and ("Checked off (%s)."):format(diff)
            or ("All roll loot collected (%s)."):format(diff), 0.3, 1, 0.3, true)
        GameTooltip:AddLine("Right-click: un-check.", 0.7, 0.7, 0.7)
    elseif s.planned then
        GameTooltip:AddLine(("Planned this week (%s)."):format(diff), 1, 0.85, 0.1)
        GameTooltip:AddLine("Click: unplan.  Right-click: check off.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(("Click: plan this boss (%s)."):format(diff), 1, 1, 1)
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    if s.rec then
        GameTooltip:AddLine(("Rolled this week: %s"):format(s.rec.link or s.rec.result or "?"), 0.3, 1, 0.3, true)
    end
    if not s.done then
        local simKey = RollSimKey(s.diff)
        local evValue, remaining = BossSimEV(s.enc, simKey, s.diff, s.diff)
        if evValue then
            GameTooltip:AddLine(("Roll EV: |cff4cde4c%s|r per coin, across the %d drops left."):format(
                FormatGainNumber(evValue, simKey), remaining), 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

local function DecorateBoss(btn)
    if not char then return end
    local m = bossMarkers[btn]
    if not m then
        m = CreateFrame("Button", nil, btn)
        m:SetSize(24, 24)
        -- raised above center so the coin + EV pair sits symmetrically
        -- in the row's right area (coin on top, value centered under it)
        m:SetPoint("RIGHT", btn, "RIGHT", -22, 7)
        m:SetFrameLevel(btn:GetFrameLevel() + 3)
        m:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        m.icon = m:CreateTexture(nil, "OVERLAY")
        m.icon:SetAllPoints()
        m.badge = m:CreateTexture(nil, "OVERLAY", nil, 2)
        m.badge:SetAtlas(TEX_CHECK)
        m.badge:SetSize(13, 13)
        m.badge:SetPoint("BOTTOMRIGHT", 4, -3)
        -- big centered check laid OVER the coin for the done state
        -- planned = Blizzard's own "selected" look: CheckButtonHilight,
        -- the yellow additive glow a checked action button wears (current
        -- stance, active form). Reads as selection at a glance.
        m.planRing = m:CreateTexture(nil, "OVERLAY", nil, 2)
        m.planRing:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        m.planRing:SetBlendMode("ADD")
        -- CheckButtonHilight fills its whole texture edge to edge: keep it
        -- BARELY larger than the 24px coin so it hugs the icon tightly
        m.planRing:SetSize(26, 26)
        m.planRing:SetPoint("CENTER")
        m.planRing:Hide()
        m.doneCheck = m:CreateTexture(nil, "OVERLAY", nil, 3)
        m.doneCheck:SetAtlas(TEX_CHECK)
        m.doneCheck:SetSize(26, 26)
        m.doneCheck:SetPoint("CENTER", 1, -1)
        m.doneCheck:Hide()
        -- sim EV readout: number only (the little voidcore lives on LOOT
        -- rows, never here), CENTERED under the coin so the pair reads as
        -- one symmetric block
        m.ev = m:CreateFontString(nil, "OVERLAY")
        m.ev:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        m.ev:SetPoint("TOP", m, "BOTTOM", 0, -1)
        m.ev:SetTextColor(0.3, 0.87, 0.3, 1)
        m:SetScript("OnClick", BossMarkerClick)
        m:SetScript("OnEnter", BossMarkerEnter)
        m:SetScript("OnLeave", function() GameTooltip:Hide() end)
        bossMarkers[btn] = m
    end
    BossMarkerUpdate(m)
end

-- LOOT rows: item-level state + estimated share.
local function ItemMarkerUpdate(m)
    local btn = m:GetParent()
    if not char or not char.settings.ejOverlay or not btn or not btn.itemID
        or not EJViewAllowed() then
        m:Hide()
        m.pct:Hide()
        return
    end
    -- rows outside the roll table get NO overlay at all: per-player Bonus
    -- Loot, slotless non-equipment, and rows whose data is still loading.
    -- EXCEPTION: a slotless TIER TOKEN row still prices - the sim values
    -- its conversion pieces, and the token is worth the best of them.
    local info = btn.index and C_EncounterJournal.GetLootInfoByIndex(btn.index) or nil
    local slotless = info and (not info.slot or info.slot == "")
    if not info or not info.name or info.displayAsPerPlayerLoot
        or (slotless and not IsTokenItem(btn.itemID)) then
        m:Hide()
        m.pct:Hide()
        if btn.name then btn.name:SetWidth(250) end   -- rows are pool-reused
        return
    end
    m:Show()
    local dungeonMode = EJDungeonMode()
    local diff = dungeonMode and MPLUS_DIFF or CurrentEJDifficulty()
    local owned, source = IsOwnedItem(btn.itemID, diff)
    m.state = { itemID = btn.itemID, enc = btn.encounterID, diff = diff,
                owned = owned, source = source, mplus = dungeonMode }
    if owned then
        -- owned = SAME visual as a finished boss: the Voidcore at full
        -- color with the green check overlaid on top
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(false)
        m.icon:SetVertexColor(1, 1, 1, 1)
        m.check:Show()
        m:SetAlpha(1)
        m.pct:Hide()
        m.pctIcon:Hide()
        m.pct2:Hide()
        m.pctIcon2:Hide()
        if btn.name then btn.name:SetWidth(250) end
    else
        -- not looted yet = GRAYED coin (still rollable, still pending);
        -- owned pieces carry the full-color coin + green check
        m.icon:SetTexture(CoinIconTexture())
        m.icon:SetDesaturated(true)
        m.icon:SetVertexColor(1, 1, 1, 1)
        m.check:Hide()
        m:SetAlpha(1)
        -- TWO tagged readouts so they can never be confused: [ALP badge]
        -- drop EV from the DROPS sim, and [coin] the bonus-roll part - its
        -- EV from the vault/bonus sim when imported, plus the share (M+
        -- share = 1 / drops left across the WHOLE dungeon). Each half
        -- follows its own toggle.
        local showShares = char.settings.showShares ~= false
        local showGains = char.settings.showGains ~= false
        local pool = showShares and (dungeonMode and GetDungeonPool()
            or (btn.encounterID and GetEncounterPool(btn.encounterID) or nil)) or nil
        local remaining = pool and (pool.total - pool.owned) or 0
        local dropTxt = ""
        if showGains then
            local gain, gainDiff
            if dungeonMode then
                gain = SimGainFor("mplus", -1, btn.itemID)
                gainDiff = "mplus"
            else
                gain = ItemGainFor(diff, btn.encounterID, btn.itemID)
                gainDiff = diff
            end
            if gain and (gain >= 0.5 or gain <= -0.5) then
                local col = gain >= 0.5 and "|cff4cde4c" or "|cff8ca0b8"
                dropTxt = ("%s%s|r"):format(col, FormatGainNumber(gain, gainDiff))
            end
        end
        local bonusTxt = ""
        -- SLOT TOKEN rows wear the coin line too (Arc's in-game correction:
        -- each token boss's roll can grant its one token; only the OMNI
        -- never rolls, and it stays drop-priced only)
        local bKeyRaid = (not dungeonMode) and RollSimKey(diff) or nil
        -- a slot token IS a coin outcome. filterType is USELESS for this
        -- (TokenLab: every token reports Other/14) - the live signal is
        -- "slotless token, not per-player, not the omni"
        local rollsToken = (slotless and IsTokenItem(btn.itemID)
            and info and not info.displayAsPerPlayerLoot
            and not OMNI_TOKENS[btn.itemID]) or false
        if showShares and (not slotless or rollsToken) then
            local bGain, bKey
            if dungeonMode then
                local instID = EJCurrentInstanceID()
                bGain = instID and SimGainFor("mplusBonus", instID, btn.itemID) or nil
                bKey = "mplusBonus"
            else
                bKey = bKeyRaid
                -- only a real vault/bonus sim prices the coin part: the drop
                -- sim's number must never wear the coin
                if bKey ~= diff then bGain = SimGainFor(bKey, btn.encounterID, btn.itemID) end
                if rollsToken and not bGain and bKey ~= diff and btn.encounterID then
                    -- the token's value = the piece outcome's gain
                    local _pc, g = GetBossTokenOutcome(btn.encounterID, bKey, diff)
                    bGain = g
                end
            end
            if bGain and (bGain >= 0.5 or bGain <= -0.5) then
                local col = bGain >= 0.5 and "|cff4cde4c" or "|cff8ca0b8"
                bonusTxt = ("%s%s|r"):format(col, FormatGainNumber(bGain, bKey))
            end
            -- share: prefer the roll-EV remaining (it counts the token
            -- outcomes too), fall back to the pool count when no sim
            local shareDen = remaining
            if not dungeonMode and btn.encounterID then
                local _bev, rr = BossSimEV(btn.encounterID, bKey, diff, diff)
                if rr and rr > 0 then shareDen = rr end
            end
            if shareDen > 0 then
                bonusTxt = bonusTxt .. (bonusTxt ~= "" and " " or "")
                    .. ("~%.0f%%"):format(100 / shareDen)
            end
        end
        -- fill the two column slots top-down: coin line first, badge line
        -- below - the icons stay in one aligned lane either way
        local lines = {}
        if bonusTxt ~= "" then lines[#lines + 1] = { icon = CoinIconTexture(), text = bonusTxt } end
        if dropTxt ~= "" then lines[#lines + 1] = { icon = LOOT_EV_ICON, text = dropTxt } end
        local slots = { { m.pctIcon, m.pct }, { m.pctIcon2, m.pct2 } }
        for i = 1, 2 do
            local e = lines[i]
            local icon, fs = slots[i][1], slots[i][2]
            if e then
                icon:SetTexture(e.icon)
                fs:SetText(e.text)
                icon:Show()
                fs:Show()
            else
                icon:Hide()
                fs:Hide()
            end
        end
        if btn.name then btn.name:SetWidth(lines[1] and 170 or 250) end
    end
end

local function ItemMarkerClick(m)
    if not char or not m.state then return end
    local s = m.state
    if s.owned and s.source == "auto" then return end   -- ledger-recorded, not togglable
    local marks = char.itemMarks[s.itemID]
    if marks and (marks[s.diff] or marks[0]) then
        marks[s.diff], marks[0] = nil, nil
        if not next(marks) then char.itemMarks[s.itemID] = nil end
    else
        char.itemMarks[s.itemID] = marks or {}
        char.itemMarks[s.itemID][s.diff] = time()
    end
    WipeLootPool()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
end

local function ItemMarkerEnter(m)
    if not m.state then return end
    local s = m.state
    GameTooltip:SetOwner(m, "ANCHOR_RIGHT")
    GameTooltip:SetText("Arc Loot Planner", 0.2, 0.8, 1)
    if s.owned then
        if s.source == "auto" then
            local won = wonItems[s.itemID]
            local rec = won and (won[s.diff] or won[0])
            GameTooltip:AddLine(("Won from a bonus roll (%s)."):format(date("%Y-%m-%d", rec and rec.t or 0)), 0.3, 1, 0.3, true)
        else
            GameTooltip:AddLine(("Checked off: already received (%s)."):format(DifficultyName(s.diff)), 0.3, 1, 0.3, true)
            GameTooltip:AddLine("Click: un-check.", 0.7, 0.7, 0.7)
        end
    else
        GameTooltip:AddLine(("Click: check off as received (%s)."):format(DifficultyName(s.diff)), 1, 1, 1)
        local pool = s.mplus and GetDungeonPool()
            or (s.enc and GetEncounterPool(s.enc) or nil)
        local remaining = pool and (pool.total - pool.owned) or 0
        if remaining > 0 then
            GameTooltip:AddLine(s.mplus
                and ("One of %d drops left across the whole dungeon - the M+ bonus roll pool is every boss together."):format(remaining)
                or ("One of %d drops you can still receive here (once per difficulty)."):format(remaining), 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

local function DecorateItem(btn)
    if not char then return end
    local m = itemMarkers[btn]
    if not m then
        m = CreateFrame("Button", nil, btn)
        m:SetSize(16, 16)
        local anchor = btn.icon or btn
        m:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
        m:SetFrameLevel(btn:GetFrameLevel() + 3)
        m:RegisterForClicks("LeftButtonUp")
        m.icon = m:CreateTexture(nil, "OVERLAY")
        m.icon:SetAllPoints()
        -- green check overlay for owned items (same look as a done boss)
        m.check = m:CreateTexture(nil, "OVERLAY", nil, 3)
        m.check:SetAtlas(TEX_CHECK)
        m.check:SetSize(18, 18)
        m.check:SetPoint("CENTER", 1, -1)
        m.check:Hide()
        -- the gain + share readout: ONE fixed right-aligned column on the
        -- NAME line (the name is width-clipped to make room - its template
        -- is TOPLEFT + fixed 250px, so SetWidth shortens it cleanly),
        -- with a mini voidcore tag - consistent, nothing floats
        -- the readout is a clean two-line COLUMN: icons aligned in their own
        -- lane (coin above, ALP badge directly below), values beside them
        m.pctIcon = m:CreateTexture(nil, "OVERLAY")
        m.pctIcon:SetSize(13, 13)
        m.pctIcon:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -104, -6)
        m.pctIcon:Hide()
        m.pct = m:CreateFontString(nil, "OVERLAY")
        m.pct:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        m.pct:SetPoint("LEFT", m.pctIcon, "RIGHT", 3, 0)
        m.pct:SetJustifyH("LEFT")
        m.pct:SetTextColor(0.25, 0.79, 0.95, 1)
        m.pctIcon2 = m:CreateTexture(nil, "OVERLAY")
        m.pctIcon2:SetSize(13, 13)
        m.pctIcon2:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -104, -22)
        m.pctIcon2:Hide()
        m.pct2 = m:CreateFontString(nil, "OVERLAY")
        m.pct2:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        m.pct2:SetPoint("LEFT", m.pctIcon2, "RIGHT", 3, 0)
        m.pct2:SetJustifyH("LEFT")
        m.pct2:SetTextColor(0.25, 0.79, 0.95, 1)
        m:SetScript("OnClick", ItemMarkerClick)
        m:SetScript("OnEnter", ItemMarkerEnter)
        m:SetScript("OnLeave", function() GameTooltip:Hide() end)
        itemMarkers[btn] = m
    end
    ItemMarkerUpdate(m)
end


-- ---- DUNGEON markers (Mythic+ bonus roll) ----------------------------------
-- The M+ roll target is the DUNGEON: one coin next to the dungeon page's
-- title, and one on each tile of the Dungeons grid. Same verbs as a boss
-- coin - click plans the dungeon, right-click checks it off.
local dungeonMarker
local tileMarkers = {}   -- [instanceTileButton] = coin

local function DungeonAutoWouldCheck(instID)
    local pool = poolStore.mplusBonus and poolStore.mplusBonus[instID]
    if not (pool and next(pool)) then return false end
    for itemID in pairs(pool) do
        if not IsOwnedItem(itemID, MPLUS_DIFF) then return false end
    end
    return true
end

local function DungeonPlanState(instID)
    local week = CurrentWeek()
    local doneFlag = char.doneBosses[BossKey(instID, MPLUS_DIFF)]
    local doneManual = doneFlag == true
    local doneAuto = doneFlag == nil and DungeonAutoWouldCheck(instID)
    return { enc = instID, diff = MPLUS_DIFF, week = week,
             planned = IsPlanned(week, instID, MPLUS_DIFF),
             done = doneManual or doneAuto, doneManual = doneManual }
end

local function DungeonMarkerPaint(m, s)
    m.icon:SetTexture(CoinIconTexture())
    if s.done then
        m.icon:SetDesaturated(false)
        m.planRing:Hide()
        m.doneCheck:Show()
    else
        m.icon:SetDesaturated(not s.planned)
        m.planRing:SetShown(s.planned)
        m.doneCheck:Hide()
    end
end

local function DungeonMarkerClick(m, mouseButton)
    if not char or not m.state then return end
    local s = m.state
    local key = BossKey(s.enc, s.diff)
    if mouseButton == "RightButton" then
        if s.done then
            char.doneBosses[key] = DungeonAutoWouldCheck(s.enc) and false or nil
        else
            char.doneBosses[key] = true
        end
    else
        if s.done then return end
        local p = char.plan[s.week]
        if p and p[key] then
            p[key] = nil
            if not next(p) then char.plan[s.week] = nil end
        else
            char.plan[s.week] = p or {}
            char.plan[s.week][key] = true
        end
    end
    RefreshEJ()
    UpdateCovers()
    if RefreshWindow then RefreshWindow() end
end

local function DungeonMarkerEnter(m)
    if not m.state then return end
    local s = m.state
    GameTooltip:SetOwner(m, "ANCHOR_RIGHT")
    GameTooltip:SetText("Arc Loot Planner", 0.2, 0.8, 1)
    if s.done then
        GameTooltip:AddLine(s.doneManual and "Checked off (Mythic+)."
            or "All M+ roll loot collected.", 0.3, 1, 0.3, true)
        GameTooltip:AddLine("Right-click: un-check.", 0.7, 0.7, 0.7)
    elseif s.planned then
        GameTooltip:AddLine("Planned this week (Mythic+ bonus roll).", 1, 0.85, 0.1)
        GameTooltip:AddLine("Click: unplan.  Right-click: check off.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(("Click: plan %s for your M+ bonus rolls."):format(
            PlanEntryName(s.enc, MPLUS_DIFF)), 1, 1, 1, true)
        GameTooltip:AddLine("One pool: every boss's loot in this dungeon counts.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    if not s.done then
        local evValue, remaining = BossSimEV(s.enc, "mplusBonus", MPLUS_DIFF)
        if evValue then
            GameTooltip:AddLine(("Roll EV: |cff4cde4c%s|r per coin, across the %d drops left."):format(
                FormatGainNumber(evValue, "mplusBonus"), remaining), 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

local function MakeDungeonCoin(parent, size)
    local m = CreateFrame("Button", nil, parent)
    m:SetSize(size, size)
    m:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    m.icon = m:CreateTexture(nil, "OVERLAY")
    m.icon:SetAllPoints()
    m.planRing = m:CreateTexture(nil, "OVERLAY", nil, 2)
    m.planRing:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    m.planRing:SetBlendMode("ADD")
    m.planRing:SetSize(size + 2, size + 2)
    m.planRing:SetPoint("CENTER")
    m.planRing:Hide()
    m.doneCheck = m:CreateTexture(nil, "OVERLAY", nil, 3)
    m.doneCheck:SetAtlas(TEX_CHECK)
    m.doneCheck:SetSize(size + 2, size + 2)
    m.doneCheck:SetPoint("CENTER", 1, -1)
    m.doneCheck:Hide()
    -- roll EV readout, boss-coin style (the title marker re-anchors its own)
    m.ev = m:CreateFontString(nil, "OVERLAY")
    m.ev:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    m.ev:SetPoint("TOP", m, "BOTTOM", 0, -1)
    m.ev:SetTextColor(0.3, 0.87, 0.3, 1)
    m:SetScript("OnClick", DungeonMarkerClick)
    m:SetScript("OnEnter", DungeonMarkerEnter)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return m
end

local function UpdateDungeonMarker()
    local info = EncounterJournal and EncounterJournal.encounter
        and EncounterJournal.encounter.info
    local host = info and info.instanceTitle
    if not host then
        if dungeonMarker then dungeonMarker:Hide() end
        return
    end
    if not dungeonMarker then
        dungeonMarker = MakeDungeonCoin(info, 26)
        dungeonMarker:SetFrameLevel(info:GetFrameLevel() + 5)
        dungeonMarker.ev:ClearAllPoints()
        dungeonMarker.ev:SetPoint("LEFT", dungeonMarker, "RIGHT", 5, 0)
    end
    local instID = EJCurrentInstanceID()
    if not (char and instID and ModuleEnabled() and char.settings.ejOverlay
        and EJViewAllowed() and EJDungeonMode())
        or char.settings.showShares == false
        or instID == MPLUS_AGGREGATE_INSTANCE then
        dungeonMarker:Hide()
        dungeonMarker.ev:SetText("")
        return
    end
    dungeonMarker.state = DungeonPlanState(instID)
    local nameW = (host.GetUnboundedStringWidth and host:GetUnboundedStringWidth())
        or host:GetStringWidth() or 0
    dungeonMarker:ClearAllPoints()
    dungeonMarker:SetPoint("LEFT", host, "LEFT", nameW + 12, 0)
    dungeonMarker:Show()
    DungeonMarkerPaint(dungeonMarker, dungeonMarker.state)
    local evValue = BossSimEV(instID, "mplusBonus", MPLUS_DIFF)
    dungeonMarker.ev:SetText(evValue and FormatGainNumber(evValue, "mplusBonus") or "")
end

local function DecorateInstanceTiles()
    local sel = EncounterJournal and EncounterJournal.instanceSelect
    local box = sel and sel.ScrollBox
    if not box then return end
    local raidTab = EncounterJournal_IsRaidTabSelected
        and EncounterJournal_IsRaidTabSelected(EncounterJournal)
    local show = char and ModuleEnabled() and char.settings.ejOverlay
        and char.settings.showOnDungeons == true and not raidTab
        and char.settings.showShares ~= false
    box:ForEachFrame(function(btn)
        local m = tileMarkers[btn]
        if not show or not btn.instanceID
            or btn.instanceID == MPLUS_AGGREGATE_INSTANCE then
            if m then m:Hide() end
            return
        end
        if not m then
            m = MakeDungeonCoin(btn, 22)
            m:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -8, -36)
            m:SetFrameLevel(btn:GetFrameLevel() + 5)
            tileMarkers[btn] = m
        end
        m.state = DungeonPlanState(btn.instanceID)
        m:Show()
        DungeonMarkerPaint(m, m.state)
        local evValue = BossSimEV(btn.instanceID, "mplusBonus", MPLUS_DIFF)
        m.ev:SetText(evValue and FormatGainNumber(evValue, "mplusBonus") or "")
    end)
end

-- Arc-styled info strip on the Adventure Guide: rolls available + planned
-- bosses + rolls used this week. Built once at journal load; position per
-- settings.stripPos (defined below, forward-declared for the refresher).
local ejStrip
local ApplyStripPosition
local EstimateLootedScan

local function RefreshEJStrip()
    if not (ejStrip and char) then return end
    if not char.settings.showStrip or not EJViewAllowed() then
        ejStrip:Hide()
        return
    end
    ejStrip:Show()
    if ejStrip.syncPctBtn then ejStrip.syncPctBtn() end
    -- re-anchor every refresh: cheap, and it picks up Raider.IO's shortcut
    -- button even though that addon creates it lazily after we first placed
    ApplyStripPosition()
    local count = BonusRollsAvailable()
    ejStrip.icon:SetTexture(CoinIconTexture())
    ejStrip.count:SetText(count and ("|cffffd100" .. count .. "|r bonus rolls") or "bonus rolls: ?")
    local week = CurrentWeek()
    -- compact boss+letter-code form; NEVER show an ellipsis: if even the
    -- compact form cannot fit, fall back to a count (hover has the list)
    local short, plannedCount = PlannedShort(week)
    if short then
        ejStrip.plan:SetText("Planned: |cffffd100" .. short .. "|r")
        if ejStrip.plan:IsTruncated() then
            ejStrip.plan:SetText(("Planned: |cffffd100%d bosses|r"):format(plannedCount))
        end
    else
        ejStrip.plan:SetText("Planned: |cff8ca0b8none - click a boss's coin|r")
    end
    if char.settings.stripCounter == "week" then
        local n = 0
        for i = 1, #char.rolls do
            if char.rolls[i].week == week then n = n + 1 end
        end
        ejStrip.used:SetText(("Rolled this week: |cffffd100%d|r"):format(n))
    else
        ejStrip.used:SetText(("Rolled: |cffffd100%d|r"):format(#char.rolls + (char.rollBaseline or 0)))
    end
end

-- three placements, Arc-picked: inside-top (under the nav bar, stops short
-- of the Raider.IO-style buttons), inside-bottom (slim band above the tab
-- row), or floating above the whole guide
ApplyStripPosition = function()
    if not (ejStrip and EncounterJournal) then return end
    local s = ejStrip
    s:ClearAllPoints()
    local dd = EncounterJournalEncounterFrameInfoDifficulty
    if dd then
        -- the Raider.IO pattern: live on the DIFFICULTY DROPDOWN, in the
        -- band above it. Parenting to the dropdown makes the strip show
        -- ONLY on an instance's encounter page (never Home/search/other
        -- tabs) with zero visibility code of our own. When Raider.IO's
        -- shortcut occupies the same band, sit to its left.
        s:SetParent(dd)
        s:SetFrameLevel(dd:GetFrameLevel() + 2)
        -- stay inside the ~23px band above the dropdown (the info panel
        -- clips its children: a taller banner gets its top shaved off)
        s:SetHeight(22)
        s:SetWidth(560)
        local ri = _G["RaiderIO_TalentBuildsEncounterJournalShortcut"]
        if ri then
            s:SetPoint("BOTTOMRIGHT", ri, "BOTTOMLEFT", -8, 0)
        else
            s:SetPoint("BOTTOMRIGHT", dd, "TOPRIGHT", 0, 1)
        end
    else -- dropdown not created yet: under the nav bar until it exists
        s:SetParent(EncounterJournal)
        s:SetFrameLevel(EncounterJournal:GetFrameLevel() + 10)
        s:SetHeight(26)
        if EncounterJournal.navBar then
            s:SetPoint("TOPLEFT", EncounterJournal.navBar, "BOTTOMLEFT", 2, -2)
        else
            s:SetPoint("TOPLEFT", EncounterJournal, "TOPLEFT", 10, -74)
        end
        s:SetPoint("RIGHT", EncounterJournal, "RIGHT", -330, 0)
    end
end

local function BuildEJStrip()
    if ejStrip or not EncounterJournal or not AT then return end
    local s = CreateFrame("Frame", nil, EncounterJournal, "BackdropTemplate")
    s:SetFrameLevel(EncounterJournal:GetFrameLevel() + 10)
    AT.Skin(s, AT.COL.bg, AT.COL.line2)
    local tag = s:CreateFontString(nil, "OVERLAY")
    tag:SetFont(STANDARD_TEXT_FONT, 12, "")
    tag:SetPoint("LEFT", 10, 0)
    tag:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r")
    s.icon = s:CreateTexture(nil, "ARTWORK")
    s.icon:SetSize(18, 18)
    s.icon:SetPoint("LEFT", tag, "RIGHT", 12, 0)
    s.count = s:CreateFontString(nil, "OVERLAY")
    s.count:SetFont(STANDARD_TEXT_FONT, 12, "")
    s.count:SetPoint("LEFT", s.icon, "RIGHT", 5, 0)
    s.count:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    s.plan = s:CreateFontString(nil, "OVERLAY")
    s.plan:SetFont(STANDARD_TEXT_FONT, 12, "")
    s.plan:SetPoint("LEFT", s.count, "RIGHT", 18, 0)
    s.plan:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    -- scans the shown loot list and CHECKS OFF what you already have.
    -- Shorter than the strip so its border never kisses the strip's edge
    -- (the clipping Arc saw when both were the same height).
    -- absolute vs percent EV, right on the guide (mirrors the /abr toggle)
    local pctBtn = AT.MakeSmallButton(s, "%", 24)
    pctBtn:SetHeight(16)
    pctBtn:SetPoint("RIGHT", -6, 0)
    local function SyncPctBtn()
        pctBtn.fs:SetText(char and char.settings.evPercent and "#" or "%")
    end
    pctBtn:SetScript("OnClick", function()
        char.settings.evPercent = not char.settings.evPercent
        SyncPctBtn()
        RefreshEJ()
        if RefreshWindow then RefreshWindow() end
    end)
    pctBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("EV display", 0.2, 0.8, 1)
        GameTooltip:AddLine("Switch the gains and roll EVs between raw DPS and percent of your simmed DPS.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    pctBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    s.syncPctBtn = SyncPctBtn

    local detect = AT.MakeSmallButton(s, "Scan gear", 78)
    detect:SetHeight(16)
    detect:SetPoint("RIGHT", pctBtn, "LEFT", -5, 0)
    detect:SetScript("OnClick", function() EstimateLootedScan() end)
    detect:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Scan gear", 0.2, 0.8, 1)
        GameTooltip:AddLine("Checks your equipped gear, bags, and transmog collection against the selected boss's loot on this difficulty, and checks off what you already have.", 1, 1, 1, true)
        GameTooltip:AddLine("An estimate - click any check it makes to undo it.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    detect:HookScript("OnLeave", function() GameTooltip:Hide() end)
    s.used = s:CreateFontString(nil, "OVERLAY")
    s.used:SetFont(STANDARD_TEXT_FONT, 12, "")
    s.used:SetPoint("RIGHT", detect, "LEFT", -14, 0)
    s.used:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    -- the planned list is the flex element: bound it on the right so a
    -- narrow placement TRUNCATES it instead of overlapping its neighbors
    s.plan:SetPoint("RIGHT", s.used, "LEFT", -14, 0)
    s.plan:SetJustifyH("LEFT")
    s.plan:SetWordWrap(false)
    -- hover = the full planned list, ONLY over the Planned text itself
    -- (a whole-strip hover zone annoyed more than it helped)
    local planHover = CreateFrame("Frame", nil, s)
    planHover:SetAllPoints(s.plan)
    planHover:EnableMouse(true)
    planHover:SetScript("OnEnter", function(self)
        if not char then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Planned this week", 0.2, 0.8, 1)
        local names = PlannedNames(CurrentWeek())
        GameTooltip:AddLine(names or "none", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    planHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ejStrip = s
    ApplyStripPosition()
    EncounterJournal:HookScript("OnShow", RefreshEJStrip)
    RefreshEJStrip()
end

RefreshEJ = function()
    for _, m in pairs(bossMarkers) do
        if m:GetParent() and m:GetParent():IsVisible() then BossMarkerUpdate(m) end
    end
    for _, m in pairs(itemMarkers) do
        if m:GetParent() and m:GetParent():IsVisible() then ItemMarkerUpdate(m) end
    end
    UpdateDungeonMarker()
    DecorateInstanceTiles()
    RefreshEJStrip()
end

-- The Scan gear button: scan the loot the journal is showing - scoped to
-- the SELECTED BOSS when one is selected (instance overview scans the
-- visible list) - against equipped gear, bags, and the transmog
-- collection, and write a normal check mark for every item found on the
-- player. Same mark as a manual click, so any of them can be un-clicked.
EstimateLootedScan = function()
    if not char then return end
    if not (EncounterJournal and EncounterJournal:IsShown()) then return end
    local diff = (EJ_GetDifficulty and EJ_GetDifficulty()) or 0
    local selectedBoss = EncounterJournal.encounterID
    WipeDetectCache()
    local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
    for i = 1, n do
        local info = C_EncounterJournal.GetLootInfoByIndex(i)
        if info and info.itemID and info.link and not info.displayAsPerPlayerLoot
            and info.slot and info.slot ~= ""
            and (not selectedBoss or info.encounterID == selectedBoss) then
            if not IsOwnedItem(info.itemID, diff)
                and DetectOwnedByLink(info.link, info.itemID) then
                char.itemMarks[info.itemID] = char.itemMarks[info.itemID] or {}
                char.itemMarks[info.itemID][diff] = time()
            end
        end
    end
    WipeLootPool()
    RefreshEJ()
    if RefreshWindow then RefreshWindow() end
end

-- SETTLE PASS: journal loot data streams in asynchronously, so a repaint
-- fired inside the change event can run against half-settled state (the
-- "% vanishes on the first boss switch" bug). One debounced repaint after
-- things land makes the final state authoritative.
local ejSettlePending = false
local function EJSettle()
    ejSettlePending = false
    if not (EncounterJournal and EncounterJournal:IsShown()) then return end
    WipeLootPool()
    RefreshEJ()
end
local function ScheduleEJSettle()
    if ejSettlePending then return end
    ejSettlePending = true
    C_Timer.After(0.25, EJSettle)
end

local ejHooked = false
local function InstallEJHooks()
    if ejHooked then return end
    if not (EncounterJournalItemMixin and EncounterBossButtonMixin) then return end
    ejHooked = true
    hooksecurefunc(EncounterBossButtonMixin, "Init", function(self) DecorateBoss(self) end)
    hooksecurefunc(EncounterJournalItemMixin, "Init", function(self) DecorateItem(self) end)
    if EncounterJournal_LootUpdate then
        hooksecurefunc("EncounterJournal_LootUpdate", function()
            WipeLootPool()
            ScheduleEJSettle()
        end)
    end
    -- difficulty dropdown / boss select run a full journal refresh; repaint
    -- AFTER it so per-difficulty badges and pools track the dropdown
    if EncounterJournal_Refresh then
        hooksecurefunc("EncounterJournal_Refresh", function()
            WipeLootPool()
            RefreshEJ()
            ScheduleEJSettle()
        end)
    end
    -- the Dungeons/Raids grid: decorate its tiles whenever the list is
    -- (re)built - After(0) lets the ScrollBox finish laying frames out
    if EncounterJournal_ListInstances then
        hooksecurefunc("EncounterJournal_ListInstances", function()
            C_Timer.After(0, DecorateInstanceTiles)
        end)
    end
    BuildEJStrip()
end

-- ── Item tooltips (anywhere): flag items won from a roll ────────────────────
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip then return end
        if not ModuleEnabled() or not char.settings.tooltips then return end
        local rec = data and data.id and wonItems[data.id]
        if rec then
            tooltip:AddLine(COLOR .. "Arc Loot Planner:|r won from a bonus roll " .. date("%Y-%m-%d", rec.t or 0), 0.4, 0.8, 1)
        end
    end)
end

-- ---- Sim value on the group loot roll window --------------------------------
-- The ALP badge + drop value from the DROPS sim, floating right after the
-- item name on the real need/greed frames (GroupLootFrame1-4) - priced by
-- the instance you are standing in (raid difficulty bucket, or the M+ runs
-- bucket in a keystone). Read-only decoration on Blizzard's frames.
local lootRollTags = {}   -- [GroupLootFrame] = badge holder
local mockLootFrame       -- "lootroll" slash: placement tester
local lootRollForce = false   -- "lootroll force": fake value on real rolls
local rollMeasureFS       -- shared ruler for the wrap simulation below

-- Where does the item name's VISIBLE text end? A wrapped FontString only
-- reports its unwrapped width, so simulate the 125px greedy word wrap the
-- Name box performs and measure the LAST line. Returns width, lineCount.
local function NameLastLineWidth(nameFS, boxW)
    local text = nameFS and nameFS:GetText()
    if not text or text == "" then return 0, 1 end
    if not rollMeasureFS then
        rollMeasureFS = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        rollMeasureFS:Hide()
    end
    local fs = rollMeasureFS
    local function width(s)
        fs:SetText(s)
        return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
            or fs:GetStringWidth() or 0
    end
    if width(text) <= boxW then return width(text), 1 end
    local lines, cur = 1, ""
    for word in text:gmatch("%S+") do
        local trial = (cur == "") and word or (cur .. " " .. word)
        if width(trial) <= boxW or cur == "" then
            cur = trial
        else
            lines = lines + 1
            cur = word
        end
    end
    return width(cur), lines
end

local function DropGainForHere(itemID)
    if not itemID or not char then return nil end
    local _, instanceType, difficultyID = GetInstanceInfo()
    if type(difficultyID) ~= "number" then return nil end
    if instanceType == "party" then
        local ev = simStore.mplus
        local g = ev and ev.gains[-1]
        local gain = g and g[itemID] or nil
        return gain, "mplus"
    end
    local ev = simStore[difficultyID]
    if ev then
        for _, gains in pairs(ev.gains) do
            local g = gains[itemID]
            if g then return g, difficultyID end
        end
        -- a TIER TOKEN roll: the token itself is never simmed - price it as
        -- the best un-collected conversion piece. Without a pool entry the
        -- token cannot be tied to one boss, so take the best orphan across
        -- this difficulty's bosses (close enough for a live roll readout).
        if IsTokenItem(itemID) then
            local pools = poolStore[difficultyID]
            if pools then
                local best
                for enc in pairs(pools) do
                    local g = OrphanTokenGain(difficultyID, enc)
                    if g and (not best or g > best) then best = g end
                end
                if best then return best, difficultyID end
            end
        end
    end
    return nil
end

local function DecorateLootRoll(frame)
    if not char then return end
    local plq = lootRollTags[frame]
    if not ModuleEnabled() or char.settings.lootRollSim == false then
        if plq then plq:Hide() end
        return
    end
    if not plq then
        plq = CreateFrame("Frame", nil, frame)
        plq:SetHeight(20)
        plq.icon = plq:CreateTexture(nil, "OVERLAY")
        plq.icon:SetSize(20, 20)   -- the chest needs a touch more room than the disc
        plq.icon:SetPoint("LEFT", 0, 0)
        plq.icon:SetTexture(ROLL_BADGE_ICON)
        plq.text = plq:CreateFontString(nil, "OVERLAY")
        plq.text:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        plq.text:SetPoint("LEFT", plq.icon, "RIGHT", 4, 0)
        lootRollTags[frame] = plq
    end
    local gain = frame._arcTestGain
    local key = frame._arcTestGain and 15 or nil
    if gain == nil then
        local link = frame.rollID and GetLootRollItemLink
            and GetLootRollItemLink(frame.rollID) or nil
        gain, key = DropGainForHere(ItemIDFromLink(link))
    end
    if gain == nil and lootRollForce and frame.rollID then
        gain, key = 1234, 15   -- force mode: prove the tag on a REAL roll
    end
    if gain and (gain >= 0.5 or gain <= -0.5) then
        local col = gain >= 0.5 and "|cff4cde4c" or "|cff8ca0b8"
        plq.text:SetText(("%s%s|r"):format(col, FormatGainNumber(gain, key)))
        local tw = (plq.text.GetUnboundedStringWidth and plq.text:GetUnboundedStringWidth())
            or plq.text:GetStringWidth() or 40
        plq:SetWidth(20 + 4 + tw)
        plq:ClearAllPoints()
        if frame.Name then
            local lw, lines = NameLastLineWidth(frame.Name, 125)
            plq:SetPoint("LEFT", frame.Name, "LEFT",
                math.min(lw, 125) + 5, (lines >= 2) and -8 or 0)
        else
            plq:SetPoint("LEFT", frame, "LEFT", 190, 4)
        end
        plq:Show()
    else
        plq:Hide()
    end
end

for i = 1, 4 do
    local frame = _G["GroupLootFrame" .. i]
    if frame then
        frame:HookScript("OnShow", DecorateLootRoll)
    end
end

-- "lootroll" slash: a REPLICA roll window for placement testing (the real
-- frame removes itself on a fake rollID, so the mock is built from the
-- same template with the scripts stripped and clicks neutered).
local function ToggleMockLootRoll()
    if mockLootFrame and mockLootFrame:IsShown() then
        mockLootFrame:Hide()
        return
    end
    if not mockLootFrame then
        local f = CreateFrame("Frame", nil, UIParent, "GroupLootFrameTemplate")
        f:SetScript("OnShow", nil)
        f:SetScript("OnHide", nil)
        f:SetScript("OnEvent", nil)
        f:SetScript("OnUpdate", nil)
        f:UnregisterAllEvents()
        f:SetPoint("CENTER", 0, 120)
        f:SetFrameStrata("DIALOG")
        for _, b in ipairs({ f.NeedButton, f.GreedButton, f.PassButton, f.TransmogButton }) do
            if b then b:SetScript("OnClick", nil) end
        end
        if f.IconFrame then
            f.IconFrame:SetScript("OnEnter", nil)
            f.IconFrame:SetScript("OnLeave", nil)
            f.IconFrame:SetScript("OnUpdate", nil)
            f.IconFrame:SetScript("OnClick", nil)
        end
        if f.TransmogButton then f.TransmogButton:Hide() end
        if f.GreedButton then f.GreedButton:Show() end
        if f.Timer then
            f.Timer:SetMinMaxValues(0, 60000)
            f.Timer:SetValue(41000)
        end
        mockLootFrame = f
    end
    local f = mockLootFrame
    local itemID, gain = nil, nil
    for _, d in ipairs({ 15, 16, 14, 17, "mplus" }) do
        local ev = simStore[d]
        if ev then
            for _, gains in pairs(ev.gains) do
                for id, g in pairs(gains) do
                    if g and (not gain or g > gain) then itemID, gain = id, g end
                end
            end
            if itemID then break end
        end
    end
    itemID = itemID or 6948
    f.IconFrame.Icon:SetTexture(C_Item.GetItemIconByID(itemID) or 134400)
    if f.IconFrame.Count then f.IconFrame.Count:Hide() end
    f.Name:SetText(C_Item.GetItemInfo(itemID) or "Test Item")
    local quality = Enum.ItemQuality and Enum.ItemQuality.Epic or 4
    if ColorManager and ColorManager.GetAtlasDataForLootBorderItemQuality then
        local atlas = ColorManager.GetAtlasDataForLootBorderItemQuality(quality)
        if atlas and f.IconFrame.Border then f.IconFrame.Border:SetAtlas(atlas) end
    end
    local colorData = ColorManager and ColorManager.GetColorDataForItemQuality
        and ColorManager.GetColorDataForItemQuality(quality) or nil
    if colorData then
        f.Name:SetVertexColor(colorData.r, colorData.g, colorData.b)
        if f.Border then f.Border:SetVertexColor(colorData.r, colorData.g, colorData.b) end
    end
    f._arcTestGain = gain or 1234
    f:Show()
    DecorateLootRoll(f)
end

-- ── Sim import window ───────────────────────────────────────────────────────
-- The season's current raid: the instance we last saw a roll prompt in,
-- or the newest raid of the latest journal tier.
local function GetCurrentRaidInstanceID()
    -- the newest tier's raids ARE the season; the last roll-prompt
    -- instance is trusted only when it is one of them. A bonus roll in
    -- OLD content (farming Kings' Rest) used to hijack the whole page to
    -- that instance - TokenLab-proven: lastInstanceID=1041 put four
    -- Kings' Rest bosses where the Venomous Abyss belonged.
    local last = char and char.lastInstanceID
    local newest, lastIsCurrent
    if EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex then
        EJ_SelectTier(EJ_GetNumTiers())
        local i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, true)
            if not id then break end
            newest = id
            if last and id == last then lastIsCurrent = true end
            i = i + 1
        end
    end
    if lastIsCurrent then
        if db then db.currentRaidInst = last end
        return last
    end
    -- remember the season's raid whenever the walk is warm: the passive
    -- journal recorder gates its raid writes on this (browsing an OLD
    -- raid must never pollute the season pools)
    if newest and db then db.currentRaidInst = newest end
    -- cold data engine: fall back to last so the kick+retry cycle can
    -- heal us into the newest raid on a later pass
    return newest or last
end

local function OpenJournalToCurrentRaid()
    if not EncounterJournal then C_AddOns.LoadAddOn("Blizzard_EncounterJournal") end
    local inst = GetCurrentRaidInstanceID()
    if inst and EncounterJournal_OpenJournal then
        EncounterJournal_OpenJournal(nil, inst)
    elseif ToggleEncounterJournal then
        ToggleEncounterJournal()
    end
end

-- ── Background pool primer ──────────────────────────────────────────────────
-- The journal data engine IS the sources database - the same Journal
-- tables Raidbots' scripts extract from the client, live in-game. The
-- primer walks ALL of it headlessly at load: every newest-tier raid at
-- the four raid difficulties, every season dungeon at Mythic Keystone,
-- for EVERY spec of the player's class - so both overviews and the
-- journal overlays always have a confirmed pool without anyone opening
-- the guide. Runs only while the journal window is closed so it never
-- fights the real UI.
local PrimePoolCache   -- forward: refreshes, login timers and retries call it
do
    local primerActive = false
    local primerRetryQueued = false
    local primerScrubbed = false
    local primeFailed = {}      -- per-session: pages that served nothing; retried next login
    local primeLinkTried = {}   -- per-session: one link-upgrade visit per stamped page
    local PRIME_DIFFS = { 15, 16, 14, 17 }   -- 17 = Raid Finder rolls too
    -- bump to force one global re-prime after a harvest fix (":l3" = the
    -- stability-rule rework: a stamp only lands when a pass stops growing)
    local PRIME_EPOCH = ":l3"
    -- dungeon pages are asked at Keystone first, but some old-expansion
    -- season dungeons only serve loot at Mythic or Heroic headlessly
    -- (TokenLab-proven: Kings' Rest returns nothing at 8, everything at
    -- 23) - the item SET is identical across dungeon difficulties
    local DUNGEON_DIFFS = { 8, 23, 2 }

    -- the primer must not steer the journal's data engine while the real
    -- UI is using it - but "come back later" instead of giving up, so a
    -- first-install session still ends fully confirmed
    local function QueuePrimerRetry()
        if primerRetryQueued then return end
        primerRetryQueued = true
        C_Timer.After(15, function()
            primerRetryQueued = false
            PrimePoolCache()
        end)
    end

    local function EnsureSpecStore(specID)
        db.poolBySpec = db.poolBySpec or {}
        local s = db.poolBySpec[specID] or {}
        db.poolBySpec[specID] = s
        s.cache = s.cache or {}
        s.primedAt = s.primedAt or {}
        return s
    end

    -- every spec of the player's class, the current one first (the pages
    -- being looked at fill before the offspec stores do)
    local function ClassSpecList()
        local classID = select(3, UnitClass("player"))
        local cur = CurrentSpecID()
        local list = {}
        if cur then list[#list + 1] = cur end
        local getNum = C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID
            or GetNumSpecializationsForClassID
        local getInfo = GetSpecializationInfoForClassID
            or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
        local n = (classID and getNum) and getNum(classID) or 0
        for i = 1, n do
            local id = getInfo and getInfo(classID, i)
            if id and id ~= cur then list[#list + 1] = id end
        end
        return classID, list
    end

    local function SetJournalLootFilter(classID, specID)
        if EJ_SetLootFilter then EJ_SetLootFilter(classID or 0, specID or 0) end
    end

    -- a pool entry is `true` until a harvest attaches its LINK (the real
    -- per-difficulty item: tooltips, quality, the gear scan). Seeded and
    -- old entries start linkless - a STAMPED page that still holds any is
    -- re-visited once per session so links land on it too.
    local function HasLinkless(bucket, encsFilter)
        if not bucket then return false end
        if encsFilter then
            for enc in pairs(encsFilter) do
                local set = bucket[enc]
                if set then
                    for _, v in pairs(set) do
                        if v == true then return true end
                    end
                end
            end
            return false
        end
        for _, v in pairs(bucket) do
            if v == true then return true end
        end
        return false
    end

    -- one harvest PASS: read what the engine has streamed so far and merge
    -- it into the destination store (links preferred, never downgraded to
    -- true). Returns accepted gear rows, rows whose item data has not
    -- streamed yet (name still nil), and the set of what THIS pass saw -
    -- the stability rule and the reconcile both need them.
    local function PrimerHarvest(job)
        local n = (EJ_GetNumLoot and EJ_GetNumLoot()) or 0
        local accepted, coldRows = 0, 0
        local seen = {}
        local dest
        for i = 1, n do
            local info = C_EncounterJournal.GetLootInfoByIndex(i)
            if info and info.itemID then
                if not info.name then
                    coldRows = coldRows + 1
                elseif info.encounterID and not info.displayAsPerPlayerLoot
                    and info.slot and info.slot ~= "" then
                    accepted = accepted + 1
                    local cache = job.store.cache
                    if not dest then
                        if job.dungeon then
                            -- one flat pool per dungeon: every boss together
                            cache.mplusBonus = cache.mplusBonus or {}
                            dest = cache.mplusBonus[job.inst] or {}
                            cache.mplusBonus[job.inst] = dest
                        else
                            cache[job.diff] = cache[job.diff] or {}
                            dest = cache[job.diff]
                        end
                    end
                    -- MERGE, never wholesale-replace: the journal streams
                    -- loot in and a pass can catch a boss half-loaded -
                    -- replacing froze 3-of-4 pools forever
                    local slot = dest
                    if job.dungeon then
                        seen[info.itemID] = true
                    else
                        slot = dest[info.encounterID]
                        if not slot then
                            slot = {}
                            dest[info.encounterID] = slot
                        end
                        local se = seen[info.encounterID]
                        if not se then
                            se = {}
                            seen[info.encounterID] = se
                        end
                        se[info.itemID] = true
                    end
                    local v = info.link or true
                    if type(v) == "string" or slot[info.itemID] == nil then
                        slot[info.itemID] = v
                    end
                end
            end
        end
        return accepted, coldRows, seen
    end

    -- once a page proves FULLY streamed (stable pass, nothing cold), the
    -- pool is reconciled to exactly what the journal lists: stale items
    -- (removed by Blizzard, or junk merged in long ago) cannot linger.
    -- Raid reconciles only THIS instance's bosses - the difficulty bucket
    -- is shared by every raid of the tier.
    local function ReconcileJob(job, seen)
        local cache = job.store.cache
        if job.dungeon then
            local dest = cache.mplusBonus and cache.mplusBonus[job.inst]
            if dest then
                for itemID in pairs(dest) do
                    if not seen[itemID] then dest[itemID] = nil end
                end
            end
            return
        end
        local dest = cache[job.diff]
        if not (dest and job.encs) then return end
        for enc in pairs(job.encs) do
            local set = dest[enc]
            if set then
                local seenSet = seen[enc]
                if not seenSet then
                    dest[enc] = nil
                else
                    for itemID in pairs(set) do
                        if not seenSet[itemID] then set[itemID] = nil end
                    end
                end
            end
        end
    end

    -- one-time login scrub: the instance-hijack era and old recorder gaps
    -- left junk behind (Kings' Rest bosses inside the raid pools, stray
    -- difficulty buckets, stale stamps). Only runs against a WARM walk.
    local function ScrubStores(raidEncSet, raidSet, dungeonSet)
        for _, store in pairs(db.poolBySpec or {}) do
            local cache = type(store) == "table" and store.cache or nil
            if type(cache) == "table" then
                for k in pairs(cache) do
                    if not (k == "mplusBonus" or k == 14 or k == 15 or k == 16 or k == 17) then
                        cache[k] = nil
                    end
                end
                for _, d in ipairs(PRIME_DIFFS) do
                    local encs = cache[d]
                    if encs then
                        for enc in pairs(encs) do
                            if not raidEncSet[enc] then encs[enc] = nil end
                        end
                    end
                end
                if cache.mplusBonus then
                    for instID in pairs(cache.mplusBonus) do
                        if not dungeonSet[instID] then cache.mplusBonus[instID] = nil end
                    end
                end
            end
            if type(store) == "table" and type(store.primedAt) == "table" then
                for k, v in pairs(store.primedAt) do
                    if type(v) ~= "string" or not v:find(PRIME_EPOCH, 1, true) then
                        store.primedAt[k] = nil
                    end
                end
            end
        end
        if type(db.bossList) == "table" then
            for inst in pairs(db.bossList) do
                if not raidSet[inst] then db.bossList[inst] = nil end
            end
        end
    end

    PrimePoolCache = function()
        if primerActive or not ModuleEnabled() or not db then return end
        if not storesLinked then RelinkSpecStores() end
        if EncounterJournal and EncounterJournal:IsShown() then QueuePrimerRetry() return end
        if not (EJ_SelectTier and EJ_GetNumTiers and EJ_GetInstanceByIndex
            and EJ_SelectInstance and EJ_SetDifficulty and C_EncounterJournal) then return end
        -- the newest tier IS the season: its raids plus its dungeon rotation
        EJ_SelectTier(EJ_GetNumTiers())
        local raids, dungeons, dungeonSet = {}, {}, {}
        local i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, true)
            if not id then break end
            raids[#raids + 1] = id
            i = i + 1
        end
        i = 1
        while true do
            local id = EJ_GetInstanceByIndex(i, false)
            if not id then break end
            if id ~= MPLUS_AGGREGATE_INSTANCE then
                dungeons[#dungeons + 1] = id
                dungeonSet[id] = true
            end
            i = i + 1
        end
        if #raids == 0 and #dungeons == 0 then QueuePrimerRetry() return end
        table.sort(dungeons)
        -- the dungeon stamps carry the season's rotation: a rotation change
        -- automatically invalidates every dungeon pool
        local seasonKey = table.concat(dungeons, "-") .. PRIME_EPOCH
        -- per-raid encounter walks: job building and the scrub both need
        -- them; a raid the engine has not streamed yet (0 bosses) is
        -- skipped this pass and picked up by a later primer call
        local raidSet, raidEncSet, raidEncCount, raidEncsByInst = {}, {}, {}, {}
        for _, inst in ipairs(raids) do
            raidSet[inst] = true
            local mine = {}
            raidEncsByInst[inst] = mine
            local c, bi = 0, 1
            while true do
                local nm, _, bid = EJ_GetEncounterInfoByIndex(bi, inst)
                if not nm or not bid then break end
                raidEncSet[bid] = true
                mine[bid] = true
                c = c + 1
                bi = bi + 1
            end
            raidEncCount[inst] = c
        end
        local currentRaid = GetCurrentRaidInstanceID()
        if not primerScrubbed and currentRaid and (raidEncCount[currentRaid] or 0) > 0 then
            primerScrubbed = true
            ScrubStores(raidEncSet, raidSet, dungeonSet)
        end
        local classID, specs = ClassSpecList()
        if #specs == 0 then return end
        local jobs = {}
        for _, specID in ipairs(specs) do
            local store = EnsureSpecStore(specID)
            for _, inst in ipairs(raids) do
                if (raidEncCount[inst] or 0) > 0 then
                    for _, d in ipairs(PRIME_DIFFS) do
                        local key = inst .. ":" .. d
                        local sk = specID .. ":" .. key
                        local fresh = store.primedAt[key] ~= PRIME_EPOCH
                        local relink = not fresh and not primeLinkTried[sk]
                            and HasLinkless(store.cache[d], raidEncsByInst[inst])
                        if (fresh or relink) and not primeFailed[sk] then
                            if relink then primeLinkTried[sk] = true end
                            jobs[#jobs + 1] = { spec = specID, store = store,
                                                inst = inst, diff = d, stamp = key,
                                                encs = raidEncsByInst[inst] }
                        end
                    end
                end
            end
            for _, instID in ipairs(dungeons) do
                local key = "m" .. instID
                local sk = specID .. ":" .. key
                local fresh = store.primedAt[key] ~= seasonKey
                local relink = not fresh and not primeLinkTried[sk]
                    and HasLinkless(store.cache.mplusBonus and store.cache.mplusBonus[instID])
                if (fresh or relink) and not primeFailed[sk] then
                    if relink then primeLinkTried[sk] = true end
                    jobs[#jobs + 1] = { spec = specID, store = store,
                                        inst = instID, diff = MPLUS_DIFF, dungeon = true,
                                        stamp = key, stampVal = seasonKey }
                end
            end
        end
        if #jobs == 0 then return end
        primerActive = true
        -- announce a real fill ONLY when the shipped seed does not cover
        -- this season (fresh season before the addon update lands): with a
        -- current seed the pages are already full and the fill is just
        -- silent link/verify housekeeping
        local seedCurrent = NS.PoolSeed and NS.PoolSeed.dungeons == table.concat(dungeons, "-")
        if #jobs >= 10 and not seedCurrent then
            print(("|cff3fc9f2ArcUI|r Loot Planner building the loot database in the background (%d journal pages) - it will report when done."):format(#jobs))
        end
        local idx = 0
        local stamped = 0
        local passes, lastAccepted = 0, -1
        local curFilterSpec
        local job
        local nextJob, passStep
        nextJob = function()
            idx = idx + 1
            job = jobs[idx]
            if not job then
                primerActive = false
                -- leave the journal's loot filter on the player's own spec
                SetJournalLootFilter(classID, CurrentSpecID())
                WipeLootPool()
                RefreshEJ()
                if RefreshWindow then RefreshWindow() end
                if stamped > 0 and not seedCurrent then
                    print(("|cff3fc9f2ArcUI|r Loot Planner loot database confirmed - %d journal pages across your specs."):format(stamped))
                end
                return
            end
            if curFilterSpec ~= job.spec then
                SetJournalLootFilter(classID, job.spec)
                curFilterSpec = job.spec
            end
            EJ_SelectInstance(job.inst)
            EJ_SetDifficulty(job.diff)
            passes, lastAccepted = 0, -1
            C_Timer.After(0.7, passStep)
        end
        passStep = function()
            if EncounterJournal and EncounterJournal:IsShown() then
                primerActive = false   -- the real UI took over; back off
                QueuePrimerRetry()     -- and finish once it is closed again
                return
            end
            passes = passes + 1
            local accepted, coldRows, seen = PrimerHarvest(job)
            -- STABILITY RULE (TokenLab-proven): loot streams in over
            -- several passes - names, slots, whole rows arrive late
            -- (Kings' Rest served ONE row on its first probe pass). A page
            -- is only stamped confirmed when a pass stops growing and
            -- nothing is left unstreamed; stamping on first contact is how
            -- pools froze half-full before.
            local stable = accepted > 0 and accepted == lastAccepted and coldRows == 0
            -- a page that is confidently EMPTY (no gear rows, nothing still
            -- streaming, three passes running) needs no full cap - move on
            -- to the difficulty fallback / next job early
            local emptyDone = accepted == 0 and coldRows == 0 and passes >= 3
            if not stable and not emptyDone and passes < 8 then
                lastAccepted = accepted
                C_Timer.After(0.7, passStep)
                return
            end
            if accepted > 0 then
                -- a cap-stamp (page never went stable) skips the reconcile:
                -- deleting against a half-streamed list would eat real loot
                if stable then ReconcileJob(job, seen) end
                job.store.primedAt[job.stamp] = job.stampVal or PRIME_EPOCH
                stamped = stamped + 1
                -- the open page fills in progressively as its spec's
                -- pools land
                if job.spec == CurrentSpecID() and RefreshWindow then RefreshWindow() end
            else
                -- dungeon page served nothing: walk the difficulty
                -- fallback chain before giving up on it
                if job.dungeon then
                    job.dt = (job.dt or 1) + 1
                    local fb = DUNGEON_DIFFS[job.dt]
                    if fb then
                        EJ_SetDifficulty(fb)
                        passes, lastAccepted = 0, -1
                        C_Timer.After(0.7, passStep)
                        return
                    end
                end
                -- nothing on any difficulty: leave unstamped, do not
                -- hammer it again this session
                primeFailed[job.spec .. ":" .. job.stamp] = true
            end
            C_Timer.After(0.2, nextJob)
        end
        nextJob()
    end
end

-- the panel is native AceConfig now: "repaint the window" = tell Ace the
-- registered options changed (cheap no-op while the dialog is closed)
RefreshWindow = function()
    local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if reg then reg:NotifyChange("ArcUI") end
end

-- ArcUI twin: "open the panel" = open ArcUI's options at the Bonus Roll
-- tab; the embed widget attaches the host there
local function ToggleWindow()
    if NS.API and NS.API.OpenOptions then NS.API.OpenOptions() end
    C_Timer.After(0, function()
        local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
        if ACD then ACD:SelectGroup("ArcUI", "bonusroll") end
    end)
end

-- ── Minimap button (no libraries: classic rim-riding button) ────────────────
local mmBtn
local function MMUpdatePos()
    if not mmBtn then return end
    local angle = math.rad(tonumber(char and char.settings.minimapAngle) or 210)
    local r = (Minimap:GetWidth() / 2) + 5
    mmBtn:ClearAllPoints()
    mmBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function BuildMinimapButton()
    if mmBtn then return mmBtn end
    mmBtn = CreateFrame("Button", "ArcBonusRollMinimapButton", Minimap)
    mmBtn:SetSize(31, 31)
    mmBtn:SetFrameStrata("MEDIUM")
    mmBtn:SetFrameLevel(8)
    mmBtn:RegisterForClicks("LeftButtonUp")
    mmBtn:RegisterForDrag("LeftButton")
    mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local overlay = mmBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    -- the TrackingBorder ring is OFFSET inside its 53px texture - background
    -- and icon must use the LibDBIcon geometry to sit inside its circle
    local bg = mmBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = mmBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    -- the chest logo (glow-keyed); the ring is round, so mask the corners
    -- off with the portrait alpha circle
    icon:SetTexture(ROLL_BADGE_ICON)
    -- dead-center on the background disc (a TOPLEFT offset sat 1.5px left)
    icon:SetPoint("CENTER", bg, "CENTER", 0, 0)
    local mask = mmBtn:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    mmBtn.icon = icon
    mmBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            char.settings.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            MMUpdatePos()
        end)
    end)
    mmBtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    mmBtn:SetScript("OnClick", function() ToggleWindow() end)
    mmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r")
        local count = BonusRollsAvailable()
        if count then GameTooltip:AddLine(("Bonus rolls: %d"):format(count), 1, 0.82, 0) end
        GameTooltip:AddLine("Click: open.  Drag: move this button.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    mmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    MMUpdatePos()
    mmBtn:SetShown(ModuleEnabled() and char.settings.minimap ~= false)
    return mmBtn
end

ApplyMinimapButton = function()
    if not mmBtn then return end
    mmBtn.icon:SetTexture(ROLL_BADGE_ICON)
    mmBtn:SetShown(ModuleEnabled() and char.settings.minimap ~= false)
    MMUpdatePos()
end

-- ── New-week plan reminder ──────────────────────────────────────────────────
-- The plan is per raid week, so every reset silently empties it. People who
-- actually use planning (protection on, or a plan in a past week) get ONE
-- popup per moment that matters: a new week starting with no plan (login),
-- a coin landing in the bags unplanned, or a roll prompt appearing while
-- protection has nothing to protect. "Not this week" silences the week;
-- setting any plan dismisses it instantly (via UpdateCovers).
local planPopup
local planReminderSession = false

HidePlanReminder = function()
    -- auto-dismiss is for the EMPTY-plan nudge (planning something means
    -- it did its job); the vault's plan recap shows WITH a plan set, so
    -- it must not be swept away by the next covers update
    if planPopup and planPopup:IsShown() and not planPopup.recapMode then
        planPopup:Hide()
    end
end

local function BuildPlanPopup()
    if planPopup then return planPopup end
    planPopup = CreateFrame("Frame", "ArcBonusRollPlanReminder", UIParent, "BackdropTemplate")
    planPopup:SetSize(400, 104)
    planPopup:SetPoint("TOP", 0, -160)
    planPopup:SetFrameStrata("DIALOG")
    planPopup:EnableMouse(true)
    AT.Skin(planPopup, AT.COL.bg, AT.COL.arcDeep)
    local title = planPopup:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 12, "")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Bonus Roll|r")
    local body = planPopup:CreateFontString(nil, "OVERLAY")
    body:SetFont(STANDARD_TEXT_FONT, 11, "")
    body:SetPoint("TOPLEFT", 12, -30)
    body:SetPoint("TOPRIGHT", -12, -30)
    body:SetJustifyH("LEFT")
    body:SetWordWrap(true)
    body:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    planPopup.body = body
    local planBtn = AT.MakeSmallButton(planPopup, "Plan now", 110)
    planBtn:SetPoint("BOTTOMLEFT", 12, 10)
    planBtn:SetScript("OnClick", function()
        planPopup:Hide()
        ToggleWindow()
        C_Timer.After(0.1, function()
            local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
            if ACD then ACD:SelectGroup("ArcUI", "bonusroll", "overview") end
        end)
    end)
    local skipBtn = AT.MakeSmallButton(planPopup, "Not this week", 110)
    skipBtn:SetPoint("LEFT", planBtn, "RIGHT", 8, 0)
    skipBtn:SetScript("OnClick", function()
        char.planSkipWeek = CurrentWeek()
        planPopup:Hide()
    end)
    planPopup.skipBtn = skipBtn
    local close = AT.MakeSmallButton(planPopup, "x", 20)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() planPopup:Hide() end)
    return planPopup
end

-- The Great Vault UI lives in Blizzard_WeeklyRewards, loaded on demand:
-- hook its frame's OnShow whenever the addon appears (or already exists)
local vaultHooked = false
InstallVaultHook = function()
    if vaultHooked then return end
    local f = _G.WeeklyRewardsFrame
    if not (f and f.HookScript) then return end
    vaultHooked = true
    f:HookScript("OnShow", function()
        if MaybePlanReminder then MaybePlanReminder("vault") end
    end)
end

MaybePlanReminder = function(kind)
    if not ModuleEnabled() or not char.settings.planReminder then return end
    local week = CurrentWeek()
    if char.planSkipWeek == week then return end
    local planned = HasAnyPlan(week)
    -- an existing plan silences the coin/prompt alarms (protection is
    -- armed, nothing to warn about) - but the vault briefing still shows:
    -- its job with a plan set is "here are your picks, change or keep them"
    if planned and kind ~= "vault" then return end
    -- never nag someone who has never used planning at all
    local planner = planned or char.settings.protection
    if not planner then
        for wk, set in pairs(char.plan) do
            if type(wk) == "number" and wk < week and type(set) == "table" and next(set) then
                planner = true
                break
            end
        end
    end
    if not planner then return end
    if kind == "vault" then
        -- opening the Great Vault = the player is starting their raid week:
        -- the natural moment for the plan briefing, once per week
        if char.planPromptWeek == week then return end
        char.planPromptWeek = week
    else
        -- prompt/coin: the sharper in-the-moment nudges, once per session;
        -- the prompt one only matters when protection would be covering
        if planReminderSession then return end
        if kind == "prompt" and not char.settings.protection then return end
    end
    planReminderSession = true
    BuildPlanPopup()
    if kind == "prompt" then
        planPopup.body:SetText("A bonus roll is up but nothing is planned this week, so bonus roll protection is not covering anything. Pick your bosses when you get a moment.")
    elseif kind == "coin" then
        planPopup.body:SetText("You just received a bonus roll coin and nothing is planned this week. Pick the bosses you want to spend it on.")
    elseif planned then
        local short = PlannedShort(week)
        planPopup.body:SetText(("This raid week's bonus roll plan: |cffffd100%s|r. Your picks are safe - open the planner if you want to change them."):format(short or "?"))
    else
        planPopup.body:SetText("New raid week: your bonus roll plan is empty. Pick the bosses you will spend coins on, and protection covers the rest.")
    end
    planPopup.recapMode = (planned and kind == "vault") or false
    planPopup.skipBtn.fs:SetText(planPopup.recapMode and "Keep it" or "Not this week")
    planPopup:Show()
end

-- ── Mock prompt (visual test without a boss kill) ───────────────────────────
-- Builds OUR OWN replica of the prompt (never touches Blizzard's frame) so
-- the covers' look and click flow can be verified anywhere.
local mock
local function ShowMock()
    if mock then mock:SetShown(not mock:IsShown()) return end
    mock = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    mock:SetSize(300, 90)
    mock:SetPoint("CENTER", 0, -180)
    AT.Skin(mock, AT.COL.bg, AT.COL.line2)
    local label = mock:CreateFontString(nil, "OVERLAY")
    label:SetFont(STANDARD_TEXT_FONT, 12, "")
    label:SetPoint("TOP", 0, -8)
    label:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
    label:SetText("MOCK bonus roll prompt (test only)")
    local dice = AT.MakeSmallButton(mock, "Roll (mock)", 100)
    dice:SetPoint("BOTTOMLEFT", 20, 12)
    dice:SetScript("OnClick", function() Print("mock: the REAL dice would have been clicked.") end)
    local cover = CreateFrame("Button", nil, mock)
    cover:SetPoint("TOPLEFT", dice, "TOPLEFT", -3, 3)
    cover:SetPoint("BOTTOMRIGHT", dice, "BOTTOMRIGHT", 3, -3)
    cover:SetFrameLevel(dice:GetFrameLevel() + 5)
    cover:RegisterForClicks("AnyUp")
    local bg = cover:CreateTexture(nil, "ARTWORK")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.78)
    local lock = cover:CreateTexture(nil, "OVERLAY")
    lock:SetSize(16, 16)
    lock:SetPoint("CENTER")
    lock:SetTexture(TEX_LOCK)
    cover:SetScript("OnClick", function(self)
        self:Hide()
        Print("mock: cover unlocked; the mock dice button is now clickable.")
    end)
    local hint = mock:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    hint:SetPoint("BOTTOMRIGHT", -14, 16)
    hint:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
    hint:SetText("click the lock,\nthen the button")
end

-- ── Events + slash ──────────────────────────────────────────────────────────
local loginAt = 0   -- login currency sync must not read as "got a coin"
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("BONUS_ROLL_STARTED")
ev:RegisterEvent("BONUS_ROLL_RESULT")
ev:RegisterEvent("BONUS_ROLL_FAILED")
ev:RegisterEvent("BONUS_ROLL_ACTIVATE")
ev:RegisterEvent("BONUS_ROLL_DEACTIVATE")
ev:RegisterEvent("EJ_DIFFICULTY_UPDATE")
ev:RegisterEvent("EJ_LOOT_DATA_RECIEVED")   -- Blizzard's typo, really spelled this way
ev:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
ev:RegisterEvent("TRANSMOG_COLLECTION_UPDATED")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local which = ...
        if which == "Blizzard_EncounterJournal" then
            InstallEJHooks()
        elseif which == "Blizzard_WeeklyRewards" then
            InstallVaultHook()
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        local function boot()
            InitDB()
            if not char then C_Timer.After(0.5, boot) return end
            RebuildWonItems()
            if BonusRollFrame_StartBonusRoll then
                hooksecurefunc("BonusRollFrame_StartBonusRoll", OnPromptShown)
            end
            InstallEJHooks()   -- in case the journal loaded before us
            BuildMinimapButton()
            loginAt = GetTime()
            C_Timer.After(8, PrimePoolCache)
            C_Timer.After(10, function()
                if RefreshWindow then RefreshWindow() end
                RefreshEJ()
                RefreshEJStrip()
            end)
            InstallVaultHook()   -- in case the vault UI loaded before us
        end
        boot()
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- pools and sims are per-spec and SAVED: swap the live stores to
        -- the new spec's buckets. Returning to a spec brings its confirmed
        -- pools and sims straight back; nothing re-harvests unless this
        -- spec has never been primed on this raid.
        if char then
            RelinkSpecStores()
            WipeDetectCache()
            WipeLootPool()
            RefreshEJ()
            RefreshEJStrip()
            if RefreshWindow then RefreshWindow() end
            C_Timer.After(4, PrimePoolCache)
        end
        return
    end
    if event == "BONUS_ROLL_STARTED" then
        OnRollStarted()
        return
    end
    if event == "BONUS_ROLL_RESULT" then
        OnRollResult(...)
        return
    end
    if event == "BONUS_ROLL_FAILED" then
        OnRollFailed()
        return
    end
    if event == "BONUS_ROLL_ACTIVATE" or event == "BONUS_ROLL_DEACTIVATE" then
        UpdateCovers()
        return
    end
    if event == "EJ_DIFFICULTY_UPDATE" or event == "EJ_LOOT_DATA_RECIEVED" then
        -- loot data arrives ASYNC after a page/boss switch: any pool built
        -- from the partial list is wrong, so wipe, repaint, and settle
        WipeLootPool()
        RefreshEJ()
        ScheduleEJSettle()
        return
    end
    if event == "CURRENCY_DISPLAY_UPDATE" then
        RefreshEJStrip()
        if ApplyMinimapButton then ApplyMinimapButton() end
        if RefreshWindow then RefreshWindow() end
        local currencyType, _, quantityChange = ...
        -- a coin just LANDED (past the login sync storm): the natural
        -- moment to remind an unplanned week
        if currencyType and currencyType == BonusCurrencyID()
            and (quantityChange or 0) > 0 and (GetTime() - loginAt) > 30 then
            MaybePlanReminder("coin")
        end
        return
    end
    if event == "TRANSMOG_COLLECTION_UPDATED" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "BAG_UPDATE_DELAYED" then
        -- estimation only runs from the button now; just invalidate its
        -- cache so the next press sees current gear
        WipeDetectCache()
        return
    end
end)

-- /abr test: bring up the REAL BonusRollFrame prompt through Blizzard's
-- own entry function so the covers are exercised on the exact production
-- frame. Safe by construction: the fake spellID has no pending server
-- confirmation, so even clicking the real dice does nothing, and the
-- prompt times out on its own. Blizzard refuses to show the prompt at 0
-- currency, so the test borrows the first currency the character owns.
local function FindOwnedCurrencyForTest()
    -- prefer the real Voidcore when the character has any
    local vc = BonusCurrencyID()
    if vc then
        local info = C_CurrencyInfo.GetCurrencyInfo(vc)
        if info and (info.quantity or 0) > 0 then return vc end
    end
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
        for i = 1, C_CurrencyInfo.GetCurrencyListSize() do
            local info = C_CurrencyInfo.GetCurrencyListInfo(i)
            if info and not info.isHeader and (info.quantity or 0) > 0 then
                local link = C_CurrencyInfo.GetCurrencyListLink(i)
                local id = link and C_CurrencyInfo.GetCurrencyIDFromLink(link)
                if id then return id end
            end
        end
    end
    return vc
end

local function HideTestPrompt()
    if BonusRollFrame and BonusRollFrame.spellID == TEST_SPELL_ID
        and BonusRollFrame_CloseBonusRoll then
        BonusRollFrame_CloseBonusRoll()
    end
end

local function ShowTestPrompt()
    if not BonusRollFrame_StartBonusRoll then return end
    local pf = BonusRollFrame and BonusRollFrame.PromptFrame
    if pf and pf:IsShown() and BonusRollFrame.spellID ~= TEST_SPELL_ID then
        return   -- never stomp a REAL prompt
    end
    BonusRollFrame_StartBonusRoll(TEST_SPELL_ID, "", 30,
        FindOwnedCurrencyForTest(), 1, 15, 0, 0, 0)
    UpdateCovers()
    -- a REAL prompt is closed by the server's confirmation-timeout event;
    -- a fake one has no server side, so nothing would EVER close it (and
    -- roll/pass clicks are no-ops that leave it up too) - close it
    -- ourselves. Safe if a real prompt took over meanwhile: HideTestPrompt
    -- only acts while the frame still shows OUR test spellID.
    C_Timer.After(31, HideTestPrompt)
end

-- /abr wipe: erase EVERYTHING saved (all characters, all specs, the
-- account-wide pools) and reload = a true fresh-install state. Behind a
-- confirm dialog: a typo must never nuke a real ledger.
StaticPopupDialogs["ARCBONUSROLL_WIPE"] = {
    text = "Arc Loot Planner: erase THIS character's bonus roll data (history, plans, owned marks, sims) plus the account's shared pools, and reload?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        if NS.db and NS.db.char then NS.db.char.bonusRoll = nil end
        if NS.db and NS.db.global then NS.db.global.bonusRoll = nil end
        C_UI.Reload()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

SLASH_ARCBONUSROLL1 = "/arcbonusroll"
SLASH_ARCBONUSROLL2 = "/abr"
SlashCmdList["ARCBONUSROLL"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "wipe" then
        StaticPopup_Show("ARCBONUSROLL_WIPE")
        return
    end
    if msg == "mock" then
        ShowMock()
        return
    end
    if msg == "lootroll force" then
        lootRollForce = not lootRollForce
        Print(lootRollForce
            and "loot roll FORCE test ON: real roll windows show a fake +1,234 when no sim value exists. Resets on reload."
            or "loot roll force test off.")
        return
    end
    if msg == "lootroll" then
        ToggleMockLootRoll()
        return
    end
    if msg == "test" then
        ShowTestPrompt()
        return
    end
    if msg == "testoff" then
        HideTestPrompt()
        return
    end
    if msg == "sim" then
        ToggleWindow()
        C_Timer.After(0.1, function()
            local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
            if ACD then ACD:SelectGroup("ArcUI", "bonusroll", "sims") end
        end)
        return
    end
    ToggleWindow()
end

-- ── ArcUI options: NATIVE AceConfig panels ──────────────────────────────────
-- The twin's five tabs (Overview/Protection/Journal/Sims/History) rendered
-- as AceConfig sub-tabs like every other ArcUI panel (Arc's call: the navy
-- custom look stays standalone-only). Engine untouched; this is purely the
-- presentation layer. Boss/item lists use FIXED hidden-gated slots (the
-- master tree is built once) with live name/hidden functions.
local selectedEnc            -- Overview "show gear for" selection
local linkInput = ""         -- Sims: pasted Raidbots report link
local itemNamesRequested = {}
local OvRefreshList          -- forward: defined with the row-list widget below

local function OvDiff() return (char and char.settings.ovDiff) or 15 end

-- done = manual check, suppressed by an explicit false, else the auto rules
-- (pool exhausted / sim list fully owned) - same logic the surfaces share
local function BossDone(enc, diff)
    local flag = char and char.doneBosses[BossKey(enc, diff)]
    if flag == true then return true end
    if flag == false then return false end
    local pool = poolStore[diff] and poolStore[diff][enc]
    if pool and next(pool) then
        local left = 0
        for itemID in pairs(pool) do
            if not IsOwnedItem(itemID, diff) then left = left + 1 end
        end
        if left == 0 then return true end
    end
    if not BossSimEV(enc, diff) and simStore[diff] then
        local gains = simStore[diff].gains[enc]
        if gains and next(gains) then
            local any = false
            for itemID in pairs(gains) do
                if not IsOwnedItem(itemID, diff) then any = true break end
            end
            if not any then return true end
        end
    end
    return false
end

-- ── Drops tab data (raw drop pricing, no coin math) ─────────────────────────
local function DropsDiff() return (char and char.settings.dropsDiff) or 15 end

-- a boss's best un-collected positive drop gain (token pieces included:
-- they live in the gains table under their boss like any other item)
local function BossBestDrop(enc, diff)
    local ev = simStore[diff]
    local gains = ev and ev.gains[enc]
    if not gains then return nil end
    local best
    for itemID, g in pairs(gains) do
        if g > 0 and not IsOwnedItem(itemID, diff)
            and (not best or g > best) then
            best = g
        end
    end
    return best
end

-- Top 5 upgrades across the whole difficulty (deduped by item - catalyst
-- rows can repeat an item), for the gold #ranks on expanded item rows.
-- ownDiff: the ownership bucket when it differs (M+ owns under MPLUS_DIFF).
local function DropsTopRanks(diff, ownDiff)
    local ev = simStore[diff]
    if not ev then return nil end
    local bestByItem = {}
    for _, gains in pairs(ev.gains) do
        for itemID, g in pairs(gains) do
            if g > 0 and not IsOwnedItem(itemID, ownDiff or diff)
                and (not bestByItem[itemID] or g > bestByItem[itemID]) then
                bestByItem[itemID] = g
            end
        end
    end
    local arr = {}
    for itemID, g in pairs(bestByItem) do arr[#arr + 1] = { itemID = itemID, g = g } end
    table.sort(arr, function(a, b) return a.g > b.g end)
    local rank = {}
    for i = 1, math.min(5, #arr) do rank[arr[i].itemID] = i end
    return rank
end

-- current season dungeon list: live from the journal engine when it is free
-- (we select the newest tier ourselves so an open journal on an old
-- expansion can never mislead it), else the STATIC copy from a past success
local function GetSeasonDungeonList()
    local entries = {}
    if not (EncounterJournal and EncounterJournal:IsShown())
        and EJ_SelectTier and EJ_GetNumTiers and EJ_GetInstanceByIndex then
        EJ_SelectTier(EJ_GetNumTiers())
        local i = 1
        while true do
            local id, nm = EJ_GetInstanceByIndex(i, false)
            if not id then break end
            if id ~= MPLUS_AGGREGATE_INSTANCE then
                entries[#entries + 1] = { id = id, name = nm }
            end
            i = i + 1
        end
    end
    if #entries > 0 then
        db.dungeonList = entries
    elseif db and db.dungeonList then
        -- scrub the aggregate from cached lists saved before the filter
        for _, e in ipairs(db.dungeonList) do
            if e.id ~= MPLUS_AGGREGATE_INSTANCE then entries[#entries + 1] = e end
        end
    end
    return entries
end

-- expected value of ONE random drop for a whole DUNGEON: the end-of-run
-- sim has no per-dungeon identity, so intersect its pooled gains with the
-- dungeon's confirmed item set - positive gains averaged over every
-- un-collected item, the same math as a boss's roll EV
local function DropsDungeonEV(instID, ownDiff)
    local ev = simStore.mplus
    local g = ev and ev.gains[-1]
    local pool = poolStore.mplusBonus and poolStore.mplusBonus[instID]
    if not (g and pool) then return nil end
    local sum, remaining = 0, 0
    for itemID in pairs(pool) do
        if not IsOwnedItem(itemID, ownDiff) then
            remaining = remaining + 1
            local gain = g[itemID]
            if gain and gain > 0 then sum = sum + gain end
        end
    end
    if remaining > 0 and sum > 0 then return sum / remaining, remaining end
    return nil
end

local function ItemNameFor(itemID)
    local name = C_Item.GetItemNameByID(itemID)
    if name then return name end
    if not itemNamesRequested[itemID] then
        itemNamesRequested[itemID] = true
        local obj = Item:CreateFromItemID(itemID)
        obj:ContinueOnItemLoad(function()
            if RefreshWindow then RefreshWindow() end
        end)
    end
    return "..."
end

-- the selected boss's gear: the confirmed JOURNAL pool priced by the sim
-- when we have one (the coin's real table), the sim list alone otherwise.
-- simKey: the sim bucket when it differs from the pool bucket (vault).
-- withTokens: DROPS tab only - union in the tier token conversion pieces
-- the pool never lists. On the ROLLS side the SLOT tokens are appended as
-- outcomes instead (Arc's in-game correction: each token boss's roll can
-- grant its token; the omni never rolls), shown as the PIECE the token
-- becomes for this spec. ownDiff: ownership bucket when it differs from
-- the pool bucket (M+ dungeons own under MPLUS_DIFF, pool "mplusBonus").
local function GearList(enc, diff, simKey, withTokens, ownDiff)
    ownDiff = ownDiff or diff
    local ev = simStore[simKey or diff]
    local gains = ev and ev.gains[enc]
    local evLv = ev and ev.lv
    local evCv = ev and ev.cv
    local evCa = ev and ev.ca
    local cache = poolStore[diff] and poolStore[diff][enc]
    local list, remaining = {}, 0
    if cache and next(cache) then
        for itemID, v in pairs(cache) do
            local cvPiece = evCv and evCv[itemID]
            list[#list + 1] = { itemID = itemID, gain = gains and gains[itemID] or nil,
                                link = (type(v) == "string") and v or nil,
                                lv = evLv and evLv[itemID], cv = cvPiece,
                                ca = cvPiece and evCa and evCa[itemID] or nil }
            if not IsOwnedItem(itemID, ownDiff) then remaining = remaining + 1 end
        end
        if withTokens and gains then
            for itemID, g in pairs(gains) do
                if cache[itemID] == nil then
                    -- old imports credited conversions to the sim's TOKEN id:
                    -- show those as the piece they become (Arc's model)
                    local show = itemID
                    if IsTokenItem(itemID) and not OMNI_TOKENS[itemID] then
                        show = TokenPieceFor(itemID) or itemID
                    end
                    list[#list + 1] = { itemID = show, gain = g, fromToken = true,
                                        lv = evLv and (evLv[show] or evLv[itemID]) }
                end
            end
        end
    elseif gains and next(gains) then
        for itemID, g in pairs(gains) do
            if withTokens or not IsTokenItem(itemID) then
                list[#list + 1] = { itemID = itemID, gain = g, lv = evLv and evLv[itemID] }
                if not IsOwnedItem(itemID, ownDiff) then remaining = remaining + 1 end
            end
        end
    end
    if not withTokens then
        -- the boss's set token, shown as the PIECE it becomes for this
        -- spec (in the no-cache branch a piece-keyed sim entry already
        -- listed itself as a plain row)
        local hadCache = cache and next(cache) ~= nil
        local piece, tGain, tOwned, _src, inGains = GetBossTokenOutcome(enc, simKey or diff, ownDiff)
        -- never duplicate: skip when the piece is already a pool row (or a
        -- plain gains row in the no-cache branch)
        if piece and ((hadCache and not cache[piece]) or (not hadCache and not inGains)) then
            list[#list + 1] = { itemID = piece, tokenOutcome = true, gain = tGain,
                                lv = evLv and evLv[piece] }
            if not tOwned then remaining = remaining + 1 end
        end
    end
    table.sort(list, function(x, y) return (x.gain or -math.huge) > (y.gain or -math.huge) end)
    return list, remaining, (cache and next(cache)) and true or false
end

local function CsvUrlFromLink()
    -- healers: a QE Live Upgrade Finder report converts too
    local qe = linkInput:match("upgradereport/(%w+)")
    if qe then
        return "https://questionablyepic.com/api/getUpgradeReport.php?reportID=" .. qe
    end
    local id = linkInput:match("simbot/report/(%w+)") or linkInput:match("/reports/(%w+)")
    return id and ("https://www.raidbots.com/reports/" .. id .. "/data.csv") or ""
end

-- Tour demo mode: while the guided tour sits on the Bonus Roll Overview,
-- bosses with no real sim get deterministic sample EVs so a fresh install
-- reads populated. Display-only; nothing is written anywhere.
local tourDemo = false

local function BuildOverviewArgs()
    local args = {
        rolls = {
            type = "description", order = 1, fontSize = "medium",
            name = function()
                local count = BonusRollsAvailable()
                return count and ("Bonus rolls: |cffffd100%d|r"):format(count) or "Bonus rolls: ?"
            end,
        },
        diff = {
            type = "select", order = 2, name = "Difficulty", width = 1.0,
            values = { [17] = "Raid Finder", [14] = "Normal", [15] = "Heroic", [16] = "Mythic",
                       mplusBonus = "Mythic+" },
            sorting = { 17, 14, 15, 16, "mplusBonus" },
            get = function() return OvDiff() end,
            set = function(_, v)
                if char then char.settings.ovDiff = v; OvRefreshList() end
            end,
        },
        pct = {
            type = "toggle", order = 3, name = "Show EV as percent", width = 1.2,
            desc = "Show gains and roll EVs as a percent of your simmed DPS instead of raw numbers.",
            get = function() return char and char.settings.evPercent end,
            set = function(_, v)
                if not char then return end
                char.settings.evPercent = v
                RefreshEJ(); RefreshEJStrip(); OvRefreshList()
            end,
        },
        guide = {
            type = "execute", order = 4, name = "Open Adventure Guide", width = 1.2,
            func = function() OpenJournalToCurrentRaid() end,
        },
        simNotice = {
            type = "description", order = 5, fontSize = "medium",
            -- RollSimKey: a bonus-track (vault) sim prices this page too
            hidden = function() return not char or tourDemo or simStore[RollSimKey(OvDiff())] ~= nil end,
            name = function()
                local d = OvDiff()
                local label = d == "mplusBonus" and "Mythic+ bonus roll" or DifficultyName(d)
                return ("|cff3fc9f2Sim your character|r to price this page - no %s sim for %s yet. Import one on the Sim Import tab."):format(
                    label, CurrentSpecName())
            end,
        },
        list = {
            type = "description", order = 10, name = " ",
            dialogControl = "ArcBonusRollOverviewList",
            hidden = function() return not ModuleEnabled() end,
        },
        hint = {
            type = "description", order = 200,
            name = function()
                return (OvDiff() == "mplusBonus")
                    and "|cff9a9aa0Click a dungeon for its pool. Coin: click plans it, right-click checks it off. One pool per dungeon.|r"
                    or "|cff9a9aa0Click a boss to see its gear. Coin: click plans it, right-click checks it off. Per difficulty.|r"
            end,
        },
    }
    return args
end

-- Drops tab: the same boss list priced from the RAW drop sims - what each
-- boss is worth when its loot just drops for you. No coin math on this tab.
local function BuildDropsArgs()
    return {
        diff = {
            type = "select", order = 1, name = "Difficulty", width = 1.0,
            values = { [17] = "Raid Finder", [14] = "Normal", [15] = "Heroic", [16] = "Mythic",
                       mplus = "Mythic+ runs" },
            sorting = { 17, 14, 15, 16, "mplus" },
            get = function() return DropsDiff() end,
            set = function(_, v)
                if char then char.settings.dropsDiff = v; OvRefreshList() end
            end,
        },
        pct = {
            type = "toggle", order = 2, name = "Show EV as percent", width = 1.2,
            desc = "Show gains as a percent of your simmed DPS instead of raw numbers.",
            get = function() return char and char.settings.evPercent end,
            set = function(_, v)
                if not char then return end
                char.settings.evPercent = v
                RefreshEJ(); RefreshEJStrip(); OvRefreshList()
            end,
        },
        guide = {
            type = "execute", order = 3, name = "Open Adventure Guide", width = 1.2,
            func = function() OpenJournalToCurrentRaid() end,
        },
        simNotice = {
            type = "description", order = 5, fontSize = "medium",
            hidden = function() return not char or tourDemo or simStore[DropsDiff()] ~= nil end,
            name = function()
                local d = DropsDiff()
                local label = d == "mplus" and "Mythic+ runs" or DifficultyName(d)
                return ("|cff3fc9f2Sim your character|r to price this page - no %s drops sim for %s yet. Import one on the Sim Import tab."):format(
                    label, CurrentSpecName())
            end,
        },
        list = {
            type = "description", order = 10, name = " ",
            dialogControl = "ArcBonusRollDropsList",
            hidden = function() return not ModuleEnabled() end,
        },
        hint = {
            type = "description", order = 200,
            name = function()
                return (DropsDiff() == "mplus")
                    and "|cff9a9aa0Raw drop values from your Mythic+ runs sim - no coin math. Click a dungeon for its pool; gold #1-#5 mark your top upgrades.|r"
                    or "|cff9a9aa0Raw drop values from your drops sim - no bonus roll math. Click a boss for its gear; gold #1-#5 mark your top upgrades.|r"
            end,
        },
    }
end

-- ── Overview boss list: a REAL row list like the standalone's Overview,
-- restyled NEUTRAL to sit inside the Ace dialog (no Arc navy in ArcUI).
-- Hosted by a custom AceGUI widget so Ace manages its lifecycle; internal
-- clicks repaint locally and poke only the engine surfaces they change.
local ovHost
local ovMode = "rolls"   -- which tab owns the list: "rolls" | "drops"

local function OvSkin(f, selected)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0.10, 0.10, 0.12, 0.9)
    if selected then
        f:SetBackdropBorderColor(0.85, 0.70, 0.20, 1)
    else
        f:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
    end
end

-- neutral clone of the Arc scroll (grey thumb - the cyan one is standalone)
local function OvMakeScroll(parent)
    local host = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, host)
    content:SetSize(1, 1)
    host:SetScrollChild(content)
    local track = CreateFrame("Frame", nil, host, "BackdropTemplate")
    track:SetWidth(4)
    track:SetPoint("TOPRIGHT", host, "TOPRIGHT", 2, 0)
    track:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 2, 0)
    track:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    track:SetBackdropColor(0.15, 0.15, 0.18, 1)
    local thumb = track:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
    thumb:SetVertexColor(0.55, 0.55, 0.60, 0.9)
    thumb:SetPoint("TOPLEFT", 0, 0)
    thumb:SetPoint("TOPRIGHT", 0, 0)
    track:Hide()
    function host:UpdateScroll()
        local viewH = host:GetHeight() or 0
        local contentH = content:GetHeight() or 0
        local over = contentH - viewH
        if over <= 1 or viewH <= 0 then
            host:SetVerticalScroll(0)
            track:Hide()
            return
        end
        track:Show()
        local cur = math.min(host:GetVerticalScroll() or 0, over)
        if cur < 0 then cur = 0 end
        host:SetVerticalScroll(cur)
        local thumbH = math.max(20, viewH * (viewH / contentH))
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPLEFT", 0, -(viewH - thumbH) * (cur / over))
        thumb:SetPoint("TOPRIGHT", 0, -(viewH - thumbH) * (cur / over))
    end
    host:EnableMouseWheel(true)
    host:SetScript("OnMouseWheel", function(_, delta)
        local viewH = host:GetHeight() or 0
        local over = ((content:GetHeight() or 0)) - viewH
        if over <= 0 then return end
        local cur = (host:GetVerticalScroll() or 0) - delta * 40
        if cur < 0 then cur = 0 elseif cur > over then cur = over end
        host:SetVerticalScroll(cur)
        host:UpdateScroll()
    end)
    host:SetScript("OnSizeChanged", function() host:UpdateScroll() end)
    return host, content
end

local function OvCoinClick(self, mouseButton)
    local s = self.row and self.row.state
    if not (char and s) then return end
    local key = BossKey(s.enc, s.diff)
    if mouseButton == "RightButton" then
        if s.done then
            -- store FALSE exactly when auto would re-check, so the player's
            -- un-check always sticks (dungeon rows use the dungeon rule)
            local would = (s.diff == MPLUS_DIFF) and DungeonAutoWouldCheck(s.enc)
                or (s.diff ~= MPLUS_DIFF and AutoWouldCheck(s.enc, s.diff))
            char.doneBosses[key] = would and false or nil
        else
            char.doneBosses[key] = true
        end
    else
        if s.done then return end
        local plan = char.plan[s.week]
        if plan and plan[key] then
            plan[key] = nil
            if not next(plan) then char.plan[s.week] = nil end
        else
            char.plan[s.week] = plan or {}
            char.plan[s.week][key] = true
        end
    end
    UpdateCovers(); RefreshEJ(); RefreshEJStrip()
    OvRefreshList()
end

local function OvCoinTooltip(self)
    local s = self.row and self.row.state
    if not s then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(s.name or "boss", 0.2, 0.8, 1)
    local diff = DifficultyName(s.diff)
    if s.done then
        GameTooltip:AddLine(("Checked off (%s)."):format(diff), 0.3, 1, 0.3, true)
        GameTooltip:AddLine("Right-click: un-check.", 0.7, 0.7, 0.7)
    elseif s.planned then
        GameTooltip:AddLine(("Planned this week (%s)."):format(diff), 1, 0.85, 0.1)
        GameTooltip:AddLine("Click: unplan.  Right-click: check off.", 0.7, 0.7, 0.7)
    else
        GameTooltip:AddLine(("Click: plan this boss (%s)."):format(diff), 1, 1, 1)
        GameTooltip:AddLine("Right-click: check off (done rolling it).", 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function OvRowClick(self)
    local s = self.state
    if not s then return end
    selectedEnc = (selectedEnc ~= s.enc) and s.enc or nil
    OvRefreshList()
end

local function OvItemClick(self)
    local s = self.state
    if not (char and s) then return end
    local owned, source = IsOwnedItem(s.itemID, s.diff)
    if owned and source ~= "manual" then return end
    local marks = char.itemMarks[s.itemID]
    if marks and (marks[s.diff] or marks[0]) then
        marks[s.diff], marks[0] = nil, nil
        if not next(marks) then char.itemMarks[s.itemID] = nil end
    else
        char.itemMarks[s.itemID] = marks or {}
        char.itemMarks[s.itemID][s.diff] = time()
    end
    WipeLootPool(); RefreshEJ()
    OvRefreshList()
end

-- ── Sim-ilvl tooltip links ──────────────────────────────────────────────────
-- TokenLab-proven: a SINGLE bonus id from the season's level-set family
-- makes any item link render at that exact level (12846 -> 321 on a
-- base-19 probe item; simc's item_bonus data confirms the family is
-- dense and carries epic quality), and GetDetailedItemLevelInfo computes
-- synthetic links client-side. The right id per level is DISCOVERED at
-- runtime by asking the client to render candidates - nothing is
-- shipped, nothing can rot; a failed scan falls back to the base preview.
local ResolveIlvlBonus
do
    local PROBE_ITEM = 159288   -- base ilvl 19: any season-level hit is unambiguous
    local SCAN_RANGES = { { 12700, 13000 }, { 13300, 13950 }, { 12000, 12700 } }
    local cache = {}            -- [lv] = bonusID, or false = scanned, none found
    local probeReady
    ResolveIlvlBonus = function(lv)
        if type(lv) ~= "number" then return nil end
        local hit = cache[lv]
        if hit ~= nil then return hit or nil end
        local getIlvl = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo
        if not getIlvl then return nil end
        if not probeReady then
            -- the probe item must be item-cached or every render reads nil
            if not getIlvl("item:" .. PROBE_ITEM) then
                local obj = Item:CreateFromItemID(PROBE_ITEM)
                obj:ContinueOnItemLoad(function() probeReady = true end)
                return nil   -- warms in a moment; the next hover resolves
            end
            probeReady = true
        end
        local me = UnitLevel("player") or 80
        for _, range in ipairs(SCAN_RANGES) do
            for b = range[1], range[2] do
                local il = getIlvl(("item:%d::::::::%d::::1:%d"):format(PROBE_ITEM, me, b))
                if il == lv then
                    cache[lv] = b
                    return b
                end
            end
        end
        cache[lv] = false
        return nil
    end
end

local function OvItemTooltip(self)
    local s = self.state
    if not s then return end
    -- cursor-anchored: the rows span the whole list, so ANCHOR_RIGHT put
    -- the tooltip a full row-width away from the pointer
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 12, -6)
    -- any row with a known sim level gets the REAL tooltip at that level
    -- via a client-verified synthetic link - UNLESS the stored journal
    -- link already renders it (raid drops pages: the link IS the right
    -- version, and its native bonus set beats a synthetic one). Covers
    -- M+ (journal only serves base-Mythic) AND vault-priced raid rows
    -- (the coin grants the vault track, not the page's difficulty).
    local synthetic
    if s.simLv then
        local getIlvl = C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo
        local linkLv = (s.link and getIlvl) and getIlvl(s.link) or nil
        if linkLv ~= s.simLv then
            local b = ResolveIlvlBonus(s.simLv)
            if b then
                GameTooltip:SetHyperlink(("item:%d::::::::%d::::1:%d"):format(
                    s.itemID, UnitLevel("player") or 80, b))
                GameTooltip:AddLine(("Shown at your sim's item level (%d)."):format(s.simLv), 0.25, 0.79, 0.95, true)
                synthetic = true
            end
        end
    end
    if not synthetic then
        if s.link then
            -- the pool's difficulty link shows the REAL drop item level,
            -- not the base item (user report: 219 shown instead of 318)
            GameTooltip:SetHyperlink(s.link)
        else
            GameTooltip:SetItemByID(s.itemID)
            -- a bare itemID previews the BASE version only (an
            -- old-expansion dungeon item renders as low-level trash)
            if s.diff == MPLUS_DIFF then
                GameTooltip:AddLine("Base preview - the actual Mythic+ drop is a higher item level.", 0.55, 0.63, 0.76, true)
            end
        end
        if s.simLv then
            GameTooltip:AddLine(("Your sim priced this at item level %d."):format(s.simLv), 0.25, 0.79, 0.95, true)
        end
    end
    if s.simConv then
        -- the shown value comes from CONVERTING this drop (catalyst /
        -- token): say what it becomes, and what it sims uncatalyzed
        local convName = C_Item.GetItemInfo(s.simConv)
        GameTooltip:AddLine(("Best used through the Catalyst - becomes %s."):format(
            convName or "your set piece"), 0.25, 0.79, 0.95, true)
        if s.simAsTxt then
            GameTooltip:AddLine(("As dropped it sims %s - the shown value is the catalyzed use."):format(
                s.simAsTxt), 0.55, 0.63, 0.76, true)
        end
    end
    if s.owned then
        GameTooltip:AddLine(s.source == "manual"
            and "Checked off. Click to un-check." or "Won from a recorded roll.", 0.3, 1, 0.3, true)
    else
        GameTooltip:AddLine("Click: check off as already received on this difficulty.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

local function OvCreateRow(idx)
    local row = CreateFrame("Button", nil, ovHost.content, "BackdropTemplate")
    row:SetHeight(30)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", OvRowClick)
    row.portrait = row:CreateTexture(nil, "ARTWORK")
    row.portrait:SetSize(22, 22)
    row.portrait:SetPoint("LEFT", 4, 0)
    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.name:SetPoint("LEFT", 32, 0)
    row.name:SetJustifyH("LEFT")
    row.coin = CreateFrame("Button", nil, row)
    row.coin.row = row
    row.coin:SetSize(20, 20)
    row.coin:SetPoint("RIGHT", -6, 0)
    row.coin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.coin:SetScript("OnClick", OvCoinClick)
    row.coin:SetScript("OnEnter", OvCoinTooltip)
    row.coin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.coin.icon = row.coin:CreateTexture(nil, "ARTWORK")
    row.coin.icon:SetAllPoints()
    row.coin.planRing = row.coin:CreateTexture(nil, "OVERLAY", nil, 1)
    row.coin.planRing:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    row.coin.planRing:SetBlendMode("ADD")
    row.coin.planRing:SetSize(22, 22)
    row.coin.planRing:SetPoint("CENTER")
    row.coin.planRing:Hide()
    row.coin.doneCheck = row.coin:CreateTexture(nil, "OVERLAY")
    row.coin.doneCheck:SetAtlas(TEX_CHECK)
    row.coin.doneCheck:SetSize(22, 22)
    row.coin.doneCheck:SetPoint("CENTER", 1, -1)
    row.ev = row:CreateFontString(nil, "OVERLAY")
    row.ev:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.ev:SetPoint("RIGHT", -34, 0)
    row.ev:SetTextColor(0.3, 0.87, 0.3, 1)
    row.simHint = CreateFrame("Button", nil, row)
    row.simHint:SetSize(16, 16)
    row.simHint:SetPoint("RIGHT", -34, 0)
    row.simHint:RegisterForClicks("LeftButtonUp")
    local hintTex = row.simHint:CreateTexture(nil, "ARTWORK")
    hintTex:SetAllPoints()
    hintTex:SetTexture("Interface\\Common\\help-i")
    hintTex:SetVertexColor(0.6, 0.6, 0.65, 0.8)
    row.simHint:SetScript("OnClick", function()
        local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
        if ACD then ACD:SelectGroup("ArcUI", "bonusroll", "sims") end
    end)
    row.simHint:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("No sim value yet", 0.2, 0.8, 1)
        GameTooltip:AddLine("Import a Droptimizer sim on the Sim Import tab and this boss shows its real roll value in DPS. Click to go there.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.simHint:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.best = row:CreateFontString(nil, "OVERLAY")
    row.best:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    row.best:SetPoint("RIGHT", row.ev, "LEFT", -8, 0)
    row.best:SetText("|cffffd100BEST|r")
    row.rolled = row:CreateTexture(nil, "OVERLAY")
    row.rolled:SetAtlas(TEX_CHECK)
    row.rolled:SetSize(14, 14)
    row.rolled:SetPoint("RIGHT", row.best, "LEFT", -6, 0)
    ovHost.rows[idx] = row
    return row
end

local function OvCreateItemRow(idx)
    local it = CreateFrame("Button", nil, ovHost.content, "BackdropTemplate")
    it:SetHeight(24)
    OvSkin(it)
    it:RegisterForClicks("LeftButtonUp")
    it:SetScript("OnClick", OvItemClick)
    it.icon = it:CreateTexture(nil, "ARTWORK")
    it.icon:SetSize(18, 18)
    it.icon:SetPoint("LEFT", 4, 0)
    -- the item tooltip only when hovering the ICON itself (Arc's call);
    -- the hit frame forwards clicks so the whole row still toggles owned
    it.iconHit = CreateFrame("Button", nil, it)
    it.iconHit:SetAllPoints(it.icon)
    it.iconHit:RegisterForClicks("LeftButtonUp")
    it.iconHit:SetScript("OnClick", function() OvItemClick(it) end)
    it.iconHit:SetScript("OnEnter", function() OvItemTooltip(it) end)
    it.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    it.check = it:CreateTexture(nil, "OVERLAY")
    it.check:SetAtlas(TEX_CHECK)
    it.check:SetSize(18, 18)
    it.check:SetPoint("CENTER", it.icon, "CENTER", 1, -1)
    it.name = it:CreateFontString(nil, "OVERLAY")
    it.name:SetFont(STANDARD_TEXT_FONT, 11, "")
    it.name:SetPoint("LEFT", 28, 0)
    it.name:SetPoint("RIGHT", it, "RIGHT", -130, 0)
    it.name:SetJustifyH("LEFT")
    it.name:SetWordWrap(false)
    it.share = it:CreateFontString(nil, "OVERLAY")
    it.share:SetFont(STANDARD_TEXT_FONT, 11, "")
    it.share:SetPoint("RIGHT", -74, 0)
    it.share:SetTextColor(0.72, 0.72, 0.76, 1)
    it.gain = it:CreateFontString(nil, "OVERLAY")
    it.gain:SetFont(STANDARD_TEXT_FONT, 11, "")
    it.gain:SetPoint("RIGHT", -8, 0)
    ovHost.itemRows[idx] = it
    return it
end

local function EnsureOvHost()
    if ovHost then return ovHost end
    ovHost = CreateFrame("Frame", nil, UIParent)
    ovHost:Hide()
    ovHost.rows, ovHost.itemRows = {}, {}
    local scroll, content = OvMakeScroll(ovHost)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -6, 0)
    ovHost.scroll, ovHost.content = scroll, content
    -- status line for the "journal data not streamed yet" retry state
    ovHost.status = ovHost:CreateFontString(nil, "OVERLAY")
    ovHost.status:SetFont(STANDARD_TEXT_FONT, 12, "")
    ovHost.status:SetPoint("TOP", 0, -30)
    ovHost.status:SetTextColor(0.6, 0.6, 0.65, 1)
    ovHost.status:Hide()
    return ovHost
end

OvRefreshList = function()
    if not (ovHost and ovHost:IsShown() and char) then return end
    local drops = ovMode == "drops"
    local diff = drops and DropsDiff() or OvDiff()
    -- Mythic+ modes: the Bonus Rolls tab plans per DUNGEON ("mplusBonus"
    -- bucket, ownership under MPLUS_DIFF); the Drops tab prices dungeons
    -- from the pooled end-of-run sim ("mplus" bucket, gains under -1)
    local mplusRolls = (not drops) and diff == "mplusBonus"
    local mplusDrops = drops and diff == "mplus"
    local mplus = mplusRolls or mplusDrops
    local ownDiff = mplus and MPLUS_DIFF or diff
    -- rolls read the BONUS TRACK sim when imported; drops read the raw bucket
    local simKey = drops and diff or (mplusRolls and "mplusBonus" or RollSimKey(diff))
    local week = CurrentWeek()
    ovHost.content:SetWidth(math.max(200, ovHost.scroll:GetWidth() or 0))
    local rankTop = drops and DropsTopRanks(diff, ownDiff) or nil
    -- live list when the journal engine is free, else the STATIC copy from
    -- a past success - the page must never depend on the Adventure Guide
    local inst
    local entries
    if mplus then
        entries = GetSeasonDungeonList()
    else
        inst = GetCurrentRaidInstanceID()
        if inst and EJ_GetEncounterInfoByIndex then
            local bosses = {}
            local bi = 1
            while true do
                local nm, _, bid = EJ_GetEncounterInfoByIndex(bi, inst)
                if not nm or not bid then break end
                bosses[#bosses + 1] = { id = bid, name = nm }
                bi = bi + 1
            end
            if #bosses > 0 then
                db.bossList = db.bossList or {}
                db.bossList[inst] = bosses
            elseif db.bossList and db.bossList[inst] then
                bosses = db.bossList[inst]
            end
            entries = bosses
        end
    end
    local y, shown, itemsShown = 0, 0, 0
    local bestRow, bestEV
    for _, entry in ipairs(entries or {}) do
        local id, bossName = entry.id, entry.name
        shown = shown + 1
        local row = ovHost.rows[shown] or OvCreateRow(shown)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", 0, y)
        y = y - 30
        local done, planned = false, false
        if not drops then
            if mplusRolls then
                local st = DungeonPlanState(id)
                done, planned = st.done, st.planned
            else
                done = BossDone(id, diff)
                planned = IsPlanned(week, id, diff)
            end
        end
        local selected = selectedEnc == id
        row.state = { enc = id, diff = ownDiff, week = week, name = bossName,
                      planned = planned, done = done }
        local img
        if mplus then
            img = select(6, EJ_GetInstanceInfo(id))   -- the dungeon's tile image
        else
            img = select(5, EJ_GetCreatureInfo(1, id))
        end
        row.portrait:SetTexture(img or "Interface\\EncounterJournal\\UI-EJ-BOSS-Default")
        OvSkin(row, selected)
        -- drops rows carry no coin verbs: raw pricing only
        row.coin:SetShown(not drops)
        if not drops then
            row.coin.icon:SetTexture(CoinIconTexture())
            row.coin.icon:SetDesaturated(not (planned or done))
            row.coin.planRing:SetShown(planned and not done)
            row.coin.doneCheck:SetShown(done)
        end
        row.name:SetText(bossName)
        if planned then
            row.name:SetTextColor(1, 0.85, 0.1, 1)
        else
            row.name:SetTextColor(0.9, 0.9, 0.92, 1)
        end
        row.rolled:SetShown(not drops and GetRollRecord(week, id, ownDiff) ~= nil)
        row.ev:ClearAllPoints()
        row.ev:SetPoint("RIGHT", drops and -8 or -34, 0)
        row.simHint:ClearAllPoints()
        row.simHint:SetPoint("RIGHT", drops and -8 or -34, 0)
        local evValue
        if mplusDrops then
            evValue = DropsDungeonEV(id, ownDiff)
        elseif drops then
            evValue = BossBestDrop(id, diff)
        elseif mplusRolls then
            evValue = BossSimEV(id, "mplusBonus", MPLUS_DIFF)
        else
            evValue = BossSimEV(id, simKey, diff, diff)
        end
        if not evValue and tourDemo then
            -- deterministic per boss, so the sample list is stable; drops
            -- get their own seed so the two tabs do not show twin numbers
            evValue = drops and (((id * 53) % 41) * 73 + 900)
                or (((id * 37) % 47) * 61 + 800)
        end
        if evValue then
            row.ev:SetText(FormatGainNumber(evValue, simKey))
            row.simHint:Hide()
        else
            row.ev:SetText("")
            row.simHint:SetShown(not done)
        end
        row.best:Hide()
        if evValue and not done and (not bestEV or evValue > bestEV) then
            bestEV, bestRow = evValue, row
        end
        row:Show()
        if selected then
            local list, remaining, confirmed
            if mplusDrops then
                -- the dungeon's confirmed pool priced by the pooled run sim
                list, remaining, confirmed = {}, 0, false
                local pool = poolStore.mplusBonus and poolStore.mplusBonus[id]
                local g = simStore.mplus and simStore.mplus.gains[-1]
                local glv = simStore.mplus and simStore.mplus.lv
                local gcv = simStore.mplus and simStore.mplus.cv
                local gca = simStore.mplus and simStore.mplus.ca
                if pool and next(pool) then
                    confirmed = true
                    for itemID in pairs(pool) do
                        local cvPiece = gcv and gcv[itemID]
                        list[#list + 1] = { itemID = itemID, gain = g and g[itemID] or nil,
                                            lv = glv and glv[itemID], cv = cvPiece,
                                            ca = cvPiece and gca and gca[itemID] or nil }
                    end
                    table.sort(list, function(a, b)
                        return (a.gain or -math.huge) > (b.gain or -math.huge)
                    end)
                end
            elseif mplusRolls then
                list, remaining, confirmed = GearList(id, "mplusBonus", "mplusBonus", false, MPLUS_DIFF)
            else
                list, remaining, confirmed = GearList(id, diff, simKey, drops)
            end
            for _, e in ipairs(list) do
                itemsShown = itemsShown + 1
                local it = ovHost.itemRows[itemsShown] or OvCreateItemRow(itemsShown)
                it:ClearAllPoints()
                it:SetPoint("TOPLEFT", 24, y)
                it:SetPoint("TOPRIGHT", 0, y)
                y = y - 26
                local owned, source = IsOwnedItem(e.itemID, ownDiff)
                it.state = { itemID = e.itemID, diff = ownDiff, owned = owned,
                             source = source, link = e.link, simLv = e.lv, simConv = e.cv,
                             simAsTxt = e.ca and FormatGainNumber(e.ca, simKey) or nil }
                it.icon:SetTexture(C_Item.GetItemIconByID(e.itemID) or 134400)
                it.check:SetShown(owned)
                local nm = ItemNameFor(e.itemID)
                local r = rankTop and not owned and rankTop[e.itemID] or nil
                if r then nm = ("|cffffd100#%d|r "):format(r) .. nm end
                if e.cv then nm = nm .. "  |cff9a9aa0(Catalyst)|r" end
                it.name:SetText(nm)
                if owned then
                    it.share:SetText("")
                    it.gain:SetText("")
                else
                    -- drops rows have no share; token pieces have no share
                    -- either (one token backs all of them)
                    it.share:SetText((not drops and not e.fromToken and remaining > 0)
                        and ("~%.0f%%"):format(100 / remaining) or "")
                    if e.gain then
                        it.gain:SetText(FormatGainNumber(e.gain, simKey))
                        if e.gain >= 0.5 then
                            it.gain:SetTextColor(0.3, 0.87, 0.3, 1)
                        else
                            it.gain:SetTextColor(0.65, 0.65, 0.70, 1)
                        end
                    else
                        it.gain:SetText("-")
                        it.gain:SetTextColor(0.65, 0.65, 0.70, 1)
                    end
                end
                it:Show()
            end
            if #list == 0 or not confirmed then
                itemsShown = itemsShown + 1
                local it = ovHost.itemRows[itemsShown] or OvCreateItemRow(itemsShown)
                it:ClearAllPoints()
                it:SetPoint("TOPLEFT", 24, y)
                it:SetPoint("TOPRIGHT", 0, y)
                y = y - 26
                it.state = nil
                it.icon:SetTexture(134400)
                it.check:Hide()
                it.name:SetText(#list == 0
                    and (mplus
                        and "|cff9a9aa0Confirming this dungeon's pool from the game's journal data - a few seconds...|r"
                        or "|cff9a9aa0Confirming this boss's pool from the game's journal data - a few seconds...|r")
                    or (mplus
                        and "|cff9a9aa0Sim-priced list - confirming the full pool from the game's journal data...|r"
                        or "|cff9a9aa0Confirming this pool from the game's journal data - a few seconds...|r"))
                it.share:SetText("")
                it.gain:SetText("")
                it:Show()
            end
        end
    end
    if bestRow then bestRow.best:Show() end
    for k = shown + 1, #ovHost.rows do ovHost.rows[k]:Hide() end
    for k = itemsShown + 1, #ovHost.itemRows do ovHost.itemRows[k]:Hide() end
    ovHost.content:SetHeight(math.max(1, -y + 4))
    ovHost.scroll:UpdateScroll()
    -- 0 rows: the journal engine has not streamed this list yet (right
    -- after login, or the guide is parked elsewhere). Kick it awake when
    -- the real journal is closed, and retry while the page is up.
    if shown == 0 then
        local ejBusy = EncounterJournal and EncounterJournal:IsShown()
        -- kick even when inst is still unknown: discovering the instance
        -- NEEDS the tier data awake, so gating the kick on inst was a
        -- circular dead-end (page stuck on "Loading the raid list...")
        if not ejBusy and not mplus
            and EJ_SelectTier and EJ_GetNumTiers then
            EJ_SelectTier(EJ_GetNumTiers())
            if inst and EJ_SelectInstance then EJ_SelectInstance(inst) end
        end
        ovHost.status:SetText(ejBusy
            and "Waiting for the Adventure Guide to free up the journal data..."
            or (mplus and "Loading the dungeon list..." or "Loading the raid list..."))
        ovHost.status:Show()
        if not ovHost._retryArmed then
            ovHost._retryArmed = true
            C_Timer.After(ejBusy and 2 or 0.8, function()
                ovHost._retryArmed = nil
                if ovHost:IsShown() then OvRefreshList() end
            end)
        end
    else
        ovHost.status:Hide()
    end
end

do
    local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
    if AceGUI then
        -- one shared row-list host, two Ace widget types selecting its mode
        -- (only one config tab is visible at a time, so sharing is safe)
        local function RegisterListWidget(typeName, mode)
            AceGUI:RegisterWidgetType(typeName, function()
                local frame = CreateFrame("Frame", nil, UIParent)
                local widget = { frame = frame, type = typeName }
                function widget:OnAcquire()
                    self.frame:SetHeight(460)
                    ovMode = mode
                    local h = EnsureOvHost()
                    h:SetParent(self.frame)
                    h:ClearAllPoints()
                    h:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
                    h:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
                    h:Show()
                    C_Timer.After(0, OvRefreshList)   -- after Ace sizes the slot
                end
                function widget:OnRelease()
                    if ovHost then
                        ovHost:Hide()
                        ovHost:SetParent(UIParent)
                        ovHost:ClearAllPoints()
                    end
                end
                -- no-op description contract (AceConfigDialog feeds these)
                function widget:SetText() end
                function widget:SetFontObject() end
                function widget:SetImage() end
                function widget:SetImageCoords() end
                return AceGUI:RegisterAsWidget(widget)
            end, 1)
        end
        RegisterListWidget("ArcBonusRollOverviewList", "rolls")
        RegisterListWidget("ArcBonusRollDropsList", "drops")
    end
end

local function NotEnabled() return not ModuleEnabled() end

-- Master switch apply: every painted surface reacts immediately, both ways.
local function SetModuleEnabled(v)
    if not char then return end
    char.settings.enabled = v == true
    RefreshEJ()
    RefreshEJStrip()
    if ApplyMinimapButton then ApplyMinimapButton() end
    UpdateCovers()
    if char.settings.enabled then
        C_Timer.After(0.5, PrimePoolCache)
    else
        if HidePlanReminder then HidePlanReminder() end
    end
end

-- Settings > Modules master switch hooks (ArcUI Options > Settings): the
-- SAME flag as the tab's own toggle. These exports only exist when the
-- module is live (the file early-returns when the standalone owns it),
-- which the Settings accessor treats as "enabled, standalone-owned".
function NS.BonusRollIsEnabled() return ModuleEnabled() and true or false end
function NS.BonusRollSetEnabled(v) SetModuleEnabled(v == true) end

-- ── Sims tab: import-for-spec picker (this character's specs) ───────────────
local simTargetSpecID   -- nil = the spec you are on

local function SpecPickValues()
    local t = {}
    local classID = select(3, UnitClass("player"))
    local n = classID and C_SpecializationInfo
        and C_SpecializationInfo.GetNumSpecializationsForClassID
        and C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0
    for i = 1, n do
        local id, name = GetSpecializationInfoForClassID(classID, i)
        if id then t[id] = name end
    end
    return t
end

local function SpecPickSorting()
    local s = {}
    local classID = select(3, UnitClass("player"))
    local n = classID and C_SpecializationInfo
        and C_SpecializationInfo.GetNumSpecializationsForClassID
        and C_SpecializationInfo.GetNumSpecializationsForClassID(classID) or 0
    for i = 1, n do
        local id = GetSpecializationInfoForClassID(classID, i)
        if id then s[#s + 1] = id end
    end
    return s
end

local function SimTargetSpec()
    return simTargetSpecID or CurrentSpecID()
end

local function SpecLabel(specID)
    if not specID then return "?" end
    local _, name = GetSpecializationInfoForSpecID(specID)
    return name or tostring(specID)
end

-- the selected spec's sim bucket - the same shape simStore is linked to
local function SimBucketForSpec(specID)
    if not char or not specID then return nil end
    if specID == CurrentSpecID() then return simStore end
    char.specData = char.specData or {}
    local rec = char.specData[specID] or {}
    char.specData[specID] = rec
    rec.simEV = rec.simEV or {}
    return rec.simEV
end

-- ── "Show me how" import walkthrough ────────────────────────────────────────
-- Shipped screenshots (Bonus_Roll\media\howto_sims_*.png) stepping through
-- the Raw Files > data.csv shortcut. PNG paths need the extension spelled
-- out (extensionless SetTexture only resolves .blp/.tga). Twin of the
-- standalone's viewer - keep the two in sync.
local ShowHowTo
do   -- (do-block: keeps the viewer's locals off the main chunk's 200 budget)
local HOWTO_STEPS = {
    { tex = "Interface\\AddOns\\ArcUI\\Bonus_Roll\\media\\howto_sims_1.png", w = 1024, h = 490,
      text = "1. On your Raidbots report page, find the |cff3fc9f2Raw Files|r row at the bottom right, under Simulation Details. Click the three dots |cff3fc9f2...|r next to it (not the Raw Files label), then pick |cff3fc9f2data.csv|r. (Step 2's address on the Sim Import tab opens the exact same page - use whichever you prefer.)" },
    { tex = "Interface\\AddOns\\ArcUI\\Bonus_Roll\\media\\howto_sims_2.png", w = 1024, h = 557,
      text = "2. On the page that opens, select everything (|cff3fc9f2Ctrl+A|r) and copy it (|cff3fc9f2Ctrl+C|r). It is a small page - the copy is instant." },
    { tex = "Interface\\AddOns\\ArcUI\\Bonus_Roll\\media\\howto_sims_3.png", w = 1024, h = 946,
      text = "3. Back in game: pick the spec the sim is for, click into the paste box, paste (|cff3fc9f2Ctrl+V|r), then press |cff3fc9f2Accept|r. The status line confirms how many item gains were stored." },
}

local howtoWin, howtoStep
ShowHowTo = function()
    if not howtoWin then
        local IMG_W = 620
        local hw = AT.CreateWindow("ArcUILootPlannerHowTo", {
            title = "|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r - importing a sim",
            w = IMG_W + 24, h = 490, minW = IMG_W + 24, minH = 490, resizable = false,
        })
        -- must outrank the options window it is opened from (AceConfigDialog
        -- sits at FULLSCREEN_DIALOG; the theme default DIALOG hides behind it)
        hw:SetFrameStrata("FULLSCREEN_DIALOG")
        local img = hw:CreateTexture(nil, "ARTWORK")
        img:SetPoint("TOP", 0, -40)
        local imgBorder = CreateFrame("Frame", nil, hw, "BackdropTemplate")
        AT.Skin(imgBorder, { 0, 0, 0, 0 }, AT.COL.line2)
        imgBorder:SetPoint("TOPLEFT", img, -1, 1)
        imgBorder:SetPoint("BOTTOMRIGHT", img, 1, -1)
        local caption = hw:CreateFontString(nil, "OVERLAY")
        caption:SetFont(STANDARD_TEXT_FONT, 12, "")
        caption:SetPoint("BOTTOMLEFT", 14, 42)
        caption:SetPoint("BOTTOMRIGHT", -14, 42)
        caption:SetJustifyH("LEFT")
        caption:SetSpacing(3)
        caption:SetTextColor(AT.COL.ink[1], AT.COL.ink[2], AT.COL.ink[3])
        local prev = AT.MakeSmallButton(hw, "< Back", 80)
        prev:SetPoint("BOTTOMLEFT", 12, 10)
        local nxt = AT.MakeSmallButton(hw, "Next >", 80)
        nxt:SetPoint("BOTTOMRIGHT", -12, 10)
        local counter = hw:CreateFontString(nil, "OVERLAY")
        counter:SetFont(STANDARD_TEXT_FONT, 11, "")
        counter:SetPoint("BOTTOM", 0, 16)
        counter:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
        local function SetStep(i)
            howtoStep = i
            local s = HOWTO_STEPS[i]
            img:SetTexture(s.tex)
            img:ClearAllPoints()
            img:SetPoint("TOP", 0, -40)
            local iw, ih = IMG_W, math.floor(IMG_W * s.h / s.w + 0.5)
            if ih > 460 then
                -- tall shots (the in-game step) shrink to keep the window on screen
                iw = math.floor(IMG_W * 460 / ih + 0.5)
                ih = 460
            end
            img:SetSize(iw, ih)
            local topUsed = 40 + ih
            -- caption hugs the image and the window shrinks to fit the step -
            -- no dead band between screenshot and text
            caption:ClearAllPoints()
            caption:SetPoint("TOPLEFT", 14, -(topUsed + 12))
            caption:SetPoint("TOPRIGHT", -14, -(topUsed + 12))
            caption:SetText(s.text)
            local ch = math.max(20, math.ceil(caption:GetStringHeight()))
            hw:SetHeight(topUsed + 12 + ch + 48)
            counter:SetText(("Step %d of %d"):format(i, #HOWTO_STEPS))
            prev:SetShown(i > 1)
            nxt:SetShown(i < #HOWTO_STEPS)
        end
        prev:SetScript("OnClick", function() SetStep(math.max(1, (howtoStep or 1) - 1)) end)
        nxt:SetScript("OnClick", function() SetStep(math.min(#HOWTO_STEPS, (howtoStep or 1) + 1)) end)
        hw.SetStep = SetStep
        howtoWin = hw
    end
    howtoWin.SetStep(1)
    howtoWin:Show()
    howtoWin:Raise()
end
end

-- ── Standalone-addon link popup ─────────────────────────────────────────────
-- WoW cannot open a browser, so the next best thing: a small window where
-- the user picks a site (both host the same addon) and copies its address.
local ShowStandaloneLink
do   -- (do-block: same 200-local-budget relief as the viewer above)
local STANDALONE_LINKS = {
    { label = "Wago",       url = "https://addons.wago.io/addons/arclootplanner" },
    { label = "CurseForge", url = "https://www.curseforge.com/wow/addons/arc-loot-planner" },
}

local linkWin
ShowStandaloneLink = function()
    if not linkWin then
        local w = AT.CreateWindow("ArcUILootPlannerLinkPopup", {
            title = "|cff3fc9f2Arc|r|cffd5e2f2 Loot Planner|r - standalone addon",
            w = 470, h = 170, minW = 470, minH = 170, resizable = false,
        })
        -- above the (FULLSCREEN_DIALOG) options window that opens it
        w:SetFrameStrata("FULLSCREEN_DIALOG")

        local intro = w:CreateFontString(nil, "OVERLAY")
        intro:SetFont(STANDARD_TEXT_FONT, 11, "")
        intro:SetPoint("TOPLEFT", 14, -40)
        intro:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
        intro:SetText("The same planner for friends who do not run ArcUI. Pick a site:")

        local well = CreateFrame("Frame", nil, w, "BackdropTemplate")
        AT.Skin(well, AT.COL.well)
        well:SetPoint("TOPLEFT", 14, -92)
        well:SetPoint("TOPRIGHT", -14, -92)
        well:SetHeight(26)
        local eb = CreateFrame("EditBox", nil, well)
        eb:SetPoint("TOPLEFT", 8, 0)
        eb:SetPoint("BOTTOMRIGHT", -8, 0)
        eb:SetFontObject(ChatFontNormal)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        local hint = w:CreateFontString(nil, "OVERLAY")
        hint:SetFont(STANDARD_TEXT_FONT, 11, "")
        hint:SetPoint("TOPLEFT", 14, -126)
        hint:SetTextColor(AT.COL.dim[1], AT.COL.dim[2], AT.COL.dim[3])
        hint:SetText("Press |cff3fc9f2Ctrl+C|r to copy, then open it in your browser.")

        local current = 1
        local btns = {}
        local function Style()
            for j, b in ipairs(btns) do
                local sel = (j == current)
                local bc = sel and AT.COL.arc or AT.COL.steel
                b:SetBackdropBorderColor(bc[1], bc[2], bc[3], 1)
                local tc = sel and AT.COL.arc or AT.COL.ink
                b.fs:SetTextColor(tc[1], tc[2], tc[3])
            end
        end
        local function Apply(i)
            current = i
            Style()
            eb:SetText(STANDALONE_LINKS[i].url)
            eb:SetFocus()
            eb:HighlightText()
        end
        for i, l in ipairs(STANDALONE_LINKS) do
            local b = AT.MakeSmallButton(w, l.label, 110)
            b:SetPoint("TOPLEFT", 14 + (i - 1) * 118, -58)
            b:SetScript("OnClick", function() Apply(i) end)
            -- MakeSmallButton's own OnLeave resets the border to steel:
            -- re-assert the selected look after every hover
            b:SetScript("OnLeave", function(s)
                s:SetBackdropColor(AT.COL.btn[1], AT.COL.btn[2], AT.COL.btn[3], 1)
                Style()
            end)
            btns[i] = b
        end
        -- read-only in spirit: typing or cutting just restores the address
        eb:SetScript("OnTextChanged", function(self, user)
            if user then
                self:SetText(STANDALONE_LINKS[current].url)
                self:HighlightText()
            end
        end)
        eb:SetScript("OnMouseUp", function(self) self:HighlightText() end)
        w._apply = Apply
        linkWin = w
    end
    linkWin._apply(1)
    linkWin:Show()
    linkWin:Raise()
end
end

function NS.GetBonusRollOptionsTable()
    return {
        type = "group",
        name = "Loot Planner",
        childGroups = "tab",
        args = {
            enabled = {
                type = "toggle", order = 0.5, name = "Enable the Loot Planner module", width = 1.4,
                desc = "Master switch for everything Loot Planner: the Adventure Guide markers and info bar, the boss planner, bonus roll protection, drop sims, roll recording, reminders, and the minimap coin. Turn OFF to disable all of it in one click. (The standalone Arc Loot Planner addon is unaffected.)",
                get = function() return ModuleEnabled() end,
                set = function(_, v) SetModuleEnabled(v) end,
            },
            standalone = {
                type = "execute", order = 0.6, name = "Get the standalone addon", width = 1.4,
                desc = "Arc Loot Planner as its own addon - the same planner for friends who do not run ArcUI. Opens a small window with the download links ready to copy.",
                func = function() ShowStandaloneLink() end,
            },
            overview = { type = "group", name = "Bonus Roll Overview", order = 1, disabled = NotEnabled, args = BuildOverviewArgs() },
            dropsview = { type = "group", name = "Drops Overview", order = 1.5, disabled = NotEnabled, args = BuildDropsArgs() },
            protection = {
                type = "group", name = "Protection", order = 2, disabled = NotEnabled,
                args = {
                    protection = {
                        type = "toggle", order = 1, name = "Enable bonus roll protection", width = "full",
                        desc = "With planned bosses set (as many as you like, per difficulty), the roll button on every OTHER boss's prompt is covered by a lock. One click on the lock unlocks it - a speed bump, never a wall. This addon never rolls or passes for you.",
                        get = function() return char and char.settings.protection end,
                        set = function(_, v) if char then char.settings.protection = v; UpdateCovers() end end,
                    },
                    passGuard = {
                        type = "toggle", order = 2, name = "Guard Pass on your planned bosses", width = "full",
                        desc = "On your planned bosses the PASS button gets the lock instead, so you cannot misclick away the roll you saved your coin for.",
                        disabled = function() return not (char and char.settings.protection) end,
                        get = function() return char and char.settings.passGuard end,
                        set = function(_, v) if char then char.settings.passGuard = v; UpdateCovers() end end,
                    },
                    planReminder = {
                        type = "toggle", order = 3, name = "New week plan reminder", width = "full",
                        desc = "When a raid week starts with an empty plan and you have used plans or protection before, a small popup reminds you to pick your bosses - at the Great Vault, or when a coin drops. Not this week silences it; planning any boss dismisses it.",
                        get = function() return char and char.settings.planReminder end,
                        set = function(_, v) if char then char.settings.planReminder = v end end,
                    },
                    weekHeader = { type = "header", order = 10, name = "This Week" },
                    planned = {
                        type = "description", order = 11, fontSize = "medium",
                        name = function()
                            if not char then return "" end
                            local names = PlannedNames(CurrentWeek())
                            return "Planned: " .. (names and ("|cffffd100" .. names .. "|r") or "|cff8ca0b8none|r")
                        end,
                    },
                    rolled = {
                        type = "description", order = 12, fontSize = "medium",
                        name = function()
                            if not char then return "" end
                            local week, n = CurrentWeek(), 0
                            for i = 1, #char.rolls do
                                if char.rolls[i].week == week then n = n + 1 end
                            end
                            return ("Rolls recorded this week: |cffffd100%d|r"):format(n)
                        end,
                    },
                    clearPlan = {
                        type = "execute", order = 13, name = "Clear this week's plan", width = 1.2,
                        func = function()
                            if not char then return end
                            char.plan[CurrentWeek()] = nil
                            UpdateCovers(); RefreshEJ(); RefreshEJStrip()
                        end,
                    },
                },
            },
            journal = {
                type = "group", name = "Overlays", order = 3, disabled = NotEnabled,
                args = {
                    markersHeader = { type = "header", order = 0.5, name = "Adventure Guide Markers" },
                    ejOverlay = {
                        type = "toggle", order = 1, name = "Adventure Guide overlays (master)", width = "full",
                        desc = "Everything Arc adds to the Adventure Guide: plan coins, EV numbers, drop shares, and the owned check marks on loot icons. Off = the guide is untouched.",
                        get = function() return char and char.settings.ejOverlay end,
                        set = function(_, v) if char then char.settings.ejOverlay = v; RefreshEJ() end end,
                    },
                    showShares = {
                        type = "toggle", order = 1.1, name = "Bonus Roll Sim", width = 1.4,
                        desc = "Everything COIN: the coin line on each item (bonus roll EV plus ~% drop share), the plan coins on bosses, dungeon titles and dungeon tiles, and each boss's per-coin EV.",
                        disabled = function() return not (char and char.settings.ejOverlay) end,
                        get = function() return char and char.settings.showShares ~= false end,
                        set = function(_, v) if char then char.settings.showShares = v; RefreshEJ() end end,
                    },
                    showGains = {
                        type = "toggle", order = 1.2, name = "Drop Sim", width = 1.4,
                        desc = "The loot-bag line on each item: its DPS value if it drops for you, priced by your drops sim. Nothing bonus roll related.",
                        disabled = function() return not (char and char.settings.ejOverlay) end,
                        get = function() return char and char.settings.showGains ~= false end,
                        set = function(_, v) if char then char.settings.showGains = v; RefreshEJ() end end,
                    },
                    rollHeader = { type = "header", order = 15, name = "Loot Roll Window" },
                    lootRollSim = {
                        type = "toggle", order = 16, name = "Sim value on loot rolls", width = "full",
                        desc = "The Arc chest badge and drop value on need/greed roll windows, priced by your drops sim for the instance you are in.",
                        get = function() return char and char.settings.lootRollSim ~= false end,
                        set = function(_, v) if char then char.settings.lootRollSim = v end end,
                    },
                    showRaids = {
                        type = "toggle", order = 2, name = "Show on raid pages", width = 1.4,
                        desc = "Markers and the info bar on the Adventure Guide's raid pages - where bonus rolls happen.",
                        disabled = function() return not (char and char.settings.ejOverlay) end,
                        get = function() return char and char.settings.showOnRaids end,
                        set = function(_, v) if char then char.settings.showOnRaids = v; RefreshEJ(); RefreshEJStrip() end end,
                    },
                    showDungeons = {
                        type = "toggle", order = 3, name = "Show on dungeon pages", width = 1.4,
                        desc = "Also decorate dungeon (Mythic+) journal pages. Off by default: bonus roll coins drop from raid bosses.",
                        disabled = function() return not (char and char.settings.ejOverlay) end,
                        get = function() return char and char.settings.showOnDungeons end,
                        set = function(_, v) if char then char.settings.showOnDungeons = v; RefreshEJ(); RefreshEJStrip() end end,
                    },
                    tipHeader = { type = "header", order = 17, name = "Item Tooltips" },
                    tooltips = {
                        type = "toggle", order = 18, name = "Bonus roll win notes", width = "full",
                        desc = "Adds a line to any item's tooltip when you won that item from a recorded bonus roll.",
                        get = function() return char and char.settings.tooltips end,
                        set = function(_, v) if char then char.settings.tooltips = v end end,
                    },
                    scan = {
                        type = "execute", order = 5, name = "Scan gear for looted items", width = 1.4,
                        desc = "Checks your equipped gear, bags, and transmog collection against the selected boss's loot in the open Adventure Guide, and checks off what you already have.",
                        func = function() EstimateLootedScan() end,
                    },
                    openGuide = {
                        type = "execute", order = 6, name = "Open Adventure Guide", width = 1.4,
                        func = function() OpenJournalToCurrentRaid() end,
                    },
                    stripHeader = { type = "header", order = 10, name = "Adventure Guide Info Bar" },
                    showStrip = {
                        type = "toggle", order = 11, name = "Journal info bar", width = "full",
                        desc = "The Arc Loot Planner bar inside the Adventure Guide: rolls available, planned bosses, the roll counter, and the Scan gear button.",
                        get = function() return char and char.settings.showStrip end,
                        set = function(_, v) if char then char.settings.showStrip = v; RefreshEJ(); RefreshEJStrip() end end,
                    },
                    stripCounter = {
                        type = "select", order = 12, name = "Counter shows", width = 1.2,
                        values = { total = "Total bonus rolls", week = "Rolled this week" },
                        disabled = function() return not (char and char.settings.showStrip) end,
                        get = function() return char and char.settings.stripCounter end,
                        set = function(_, v) if char then char.settings.stripCounter = v; RefreshEJStrip() end end,
                    },
                    baseline = {
                        type = "input", order = 13, name = "Rolls before install", width = 0.8,
                        desc = "The addon only sees rolls made after it was installed. Add the rolls you made before, and the total counter includes them.",
                        hidden = function()
                            return not (char and char.settings.showStrip and char.settings.stripCounter == "total")
                        end,
                        get = function() return char and tostring(char.rollBaseline or 0) or "0" end,
                        set = function(_, v)
                            if not char then return end
                            char.rollBaseline = math.max(0, math.floor(tonumber(v) or 0))
                            RefreshEJStrip()
                        end,
                    },
                    mmHeader = { type = "header", order = 20, name = "Minimap" },
                    minimap = {
                        type = "toggle", order = 21, name = "Minimap button", width = "full",
                        desc = "The Arc Loot Planner chest button on the minimap. Click it to open this panel; drag it around the rim to move it.",
                        get = function() return char and char.settings.minimap end,
                        set = function(_, v)
                            if not char then return end
                            char.settings.minimap = v
                            if ApplyMinimapButton then ApplyMinimapButton() end
                        end,
                    },
                },
            },
            sims = {
                type = "group", name = "Sim Import", order = 4, disabled = NotEnabled,
                args = {
                    importHeader = { type = "header", order = 0.5, name = "Import a Raidbots Droptimizer" },
                    howto = {
                        type = "execute", order = 0.6, name = "Show me how (screenshots)", width = 1.4,
                        desc = "A three-step picture guide to importing your Droptimizer.",
                        func = ShowHowTo,
                    },
                    specStatus = {
                        type = "description", order = 0.7, fontSize = "medium",
                        name = function()
                            return ("Sims are |cffffd100per spec|r. Importing stores for: |cff3fc9f2%s|r"):format(
                                SpecLabel(SimTargetSpec()))
                        end,
                    },
                    forSpec = {
                        type = "select", order = 1, name = "For spec", width = 1.0,
                        desc = "Sims are per spec. Pick which spec this import belongs to - it defaults to the spec you are on.",
                        values = SpecPickValues,
                        sorting = SpecPickSorting,
                        get = function() return SimTargetSpec() end,
                        set = function(_, v)
                            simTargetSpecID = (v ~= CurrentSpecID()) and v or nil
                        end,
                    },
                    link = {
                        type = "input", order = 2, name = "1. Report link", width = "full",
                        desc = "Run a Raidbots Droptimizer for the selected spec, then paste the report link here. Healers: a QE Live Upgrade Finder report link works too.",
                        get = function() return linkInput end,
                        set = function(_, v) linkInput = v or "" end,
                    },
                    csvUrl = {
                        type = "input", order = 3, name = "2. Open THIS address", width = "full",
                        desc = "Copy this address (Ctrl+C), open it in your browser, select all (Ctrl+A) and copy the page. Shortcut: the Raw Files ... menu on the report page itself opens the same data.csv - press Show me how for pictures.",
                        get = function() return CsvUrlFromLink() end,
                        set = function() end,
                    },
                    paste = {
                        type = "input", order = 4, name = "3. Paste the page's FULL text, then press Accept", width = "full",
                        multiline = 6,
                        get = function() return "" end,
                        set = function(_, v)
                            local target = SimTargetSpec()
                            local diffs, items, impErr, usedSpec = ApplySimImport(
                                v, SimBucketForSpec(target), target,
                                UnitName("player"), select(3, UnitClass("player")),
                                SimBucketForSpec)
                            if diffs then
                                local finalSpec = usedSpec or target
                                simStatusMsg = ("|cff4cde4cImported %d item gains (%d difficulty set%s) for %s%s.|r"):format(
                                    items, diffs, diffs == 1 and "" or "s", SpecLabel(finalSpec),
                                    (usedSpec and usedSpec ~= target) and " (the sim said so)" or "")
                                if finalSpec == CurrentSpecID() then
                                    WipeLootPool(); RefreshEJ(); OvRefreshList()
                                end
                            else
                                if impErr then
                                    simStatusMsg = "|cffff6060" .. impErr .. "|r"
                                elseif type(v) == "string" and v:find("^%s*[%[{]") then
                                    simStatusMsg = "|cffff6060That is the data.json - not needed, and far too big. Open the data.csv instead (press Show me how).|r"
                                else
                                    simStatusMsg = "|cffff6060Could not read that. Paste the FULL text of the data.csv page.|r"
                                end
                            end
                        end,
                    },
                    wowutils = {
                        type = "execute", order = 5, name = "Import from WoWUtils", width = 1.2,
                        desc = "Reads the droptimizer data the WoWUtils addon already holds for this character and spec - no pasting needed. Newest sim per difficulty wins.",
                        func = function()
                            local diffs, itemsOrErr = ImportFromWowUtils()
                            if diffs then
                                simStatusMsg = ("|cff4cde4cImported %d item gains (%d difficulty set%s) for %s from WoWUtils.|r"):format(
                                    itemsOrErr, diffs, diffs == 1 and "" or "s", CurrentSpecName())
                                WipeLootPool(); RefreshEJ(); OvRefreshList()
                            else
                                simStatusMsg = "|cffff6060" .. tostring(itemsOrErr) .. "|r"
                            end
                        end,
                    },
                    clear = {
                        type = "execute", order = 6, name = "Clear the selected spec's sims", width = 1.4,
                        func = function()
                            local target = SimTargetSpec()
                            local b = SimBucketForSpec(target)
                            if b then wipe(b) end
                            simStatusMsg = ("|cffffd100Cleared imported sims for %s.|r"):format(SpecLabel(target))
                            if target == CurrentSpecID() then
                                WipeLootPool(); RefreshEJ(); RefreshEJStrip(); OvRefreshList()
                            end
                        end,
                    },
                    status = {
                        type = "description", order = 5.5, fontSize = "medium",
                        name = function() return simStatusMsg end,
                    },
                    pct = {
                        type = "toggle", order = 8, name = "Show EV as percent", width = "full",
                        desc = "Raidbots' Relative DPS view: gains and roll EVs show as a percent of your simmed DPS instead of raw numbers.",
                        get = function() return char and char.settings.evPercent end,
                        set = function(_, v)
                            if char then char.settings.evPercent = v; RefreshEJ(); RefreshEJStrip() end
                        end,
                    },
                    dataHeader = { type = "header", order = 10, name = "Imported Data" },
                    dataRows = {
                        type = "description", order = 11,
                        -- self-cleaning (the standalone's rule): one row per
                        -- bucket that HAS a sim; empty buckets stay silent
                        name = function()
                            if not char then return "" end
                            local target = SimTargetSpec()
                            local store = SimBucketForSpec(target) or {}
                            local LABEL = {
                                [17] = "Raid Finder drops", [14] = "Raid Normal drops",
                                [15] = "Raid Heroic drops", [16] = "Raid Mythic drops",
                                vault17 = "Raid Finder bonus rolls", vault14 = "Raid Normal bonus rolls",
                                vault15 = "Raid Heroic bonus rolls", vault16 = "Raid Mythic bonus rolls",
                                mplus = "Mythic+ run drops", mplusBonus = "Mythic+ bonus rolls",
                            }
                            local ORDER = { 17, 14, 15, 16,
                                "vault17", "vault14", "vault15", "vault16", "mplus", "mplusBonus" }
                            local lines = { ("For |cff3fc9f2%s|r:"):format(SpecLabel(target)) }
                            local any = false
                            for _, d in ipairs(ORDER) do
                                local ev = store[d]
                                if ev then
                                    any = true
                                    local n = 0
                                    if d == "mplusBonus" then
                                        for _ in pairs(ev.gains) do n = n + 1 end
                                        lines[#lines + 1] = ("%s: |cffffd100%d|r dungeon pool%s, imported %s"):format(
                                            LABEL[d], n, n == 1 and "" or "s", date("%m-%d %H:%M", ev.t or 0))
                                    else
                                        for _, encGains in pairs(ev.gains) do
                                            for _ in pairs(encGains) do n = n + 1 end
                                        end
                                        lines[#lines + 1] = ("%s: |cffffd100%d|r item gains, imported %s"):format(
                                            LABEL[d], n, date("%m-%d %H:%M", ev.t or 0))
                                    end
                                end
                            end
                            if not any then
                                lines[#lines + 1] = "|cff8ca0b8Nothing imported for this spec yet.|r"
                            end
                            return table.concat(lines, "\n")
                        end,
                    },
                },
            },
            history = {
                type = "group", name = "History", order = 5, disabled = NotEnabled,
                args = {
                    rolls = {
                        type = "description", order = 1, fontSize = "medium",
                        name = function()
                            if not char then return "" end
                            local lines = {}
                            for i = 1, math.min(#char.rolls, 60) do
                                local r = char.rolls[i]
                                local what = r.link or r.result or "?"
                                if r.qty and r.qty > 1 and r.link then what = what .. " x" .. r.qty end
                                lines[#lines + 1] = ("|cff8ca0b8%s|r  %s (%s)  %s"):format(
                                    date("%m-%d %H:%M", r.t or 0), EncounterName(r.enc), DifficultyName(r.diff), what)
                            end
                            if #lines == 0 then
                                lines[1] = "|cff8ca0b8No rolls recorded yet. They record automatically when you spend a coin.|r"
                            end
                            return table.concat(lines, "\n")
                        end,
                    },
                },
            },
        },
    }
end

-- ── Tour hooks (the ArcUI_Tour Loot Planner tour) ───────────────────────────
-- SetDemo paints sample EVs into the Bonus Roll Overview while the tour is
-- active; OpenGuide shows the raid journal for the overlays step; CloseGuide
-- puts it away again if the tour opened it. The tour's cleanup calls the
-- off-switches, so nothing here can outlive a tour.
do   -- (do-block: 200-local-budget relief)
local tourGuideWasShown
NS.BonusRollTour = {
    SetDemo = function(on)
        on = on and true or false
        if tourDemo == on then return end
        tourDemo = on
        if OvRefreshList then OvRefreshList() end
    end,
    OpenGuide = function()
        tourGuideWasShown = (EncounterJournal and EncounterJournal:IsShown()) and true or false
        local inst = GetCurrentRaidInstanceID()
        if not (inst and EncounterJournal_OpenJournal) then
            if not tourGuideWasShown then OpenJournalToCurrentRaid() end
            return true
        end
        -- instance page FIRST: on a cold journal the encounter list is
        -- data-engine async, so a boss picked before this open sees nothing
        EncounterJournal_OpenJournal(nil, inst)
        -- Boss pick: this week's planned boss, else the best coin EV, else
        -- the raid's first boss - opened on its LOOT page so the item
        -- overlays are on screen.
        local function SelectBoss()
            local plan = char and char.plan and char.plan[CurrentWeek()]
            local d = OvDiff()
            if d == "mplusBonus" then d = 15 end   -- this step shows the raid view
            local simKey = RollSimKey(d)
            local pickPlan, pickBest, bestVal, first
            for i = 1, 30 do
                local _n, _de, enc = EJ_GetEncounterInfoByIndex(i, inst)
                if not enc then break end
                first = first or enc
                if plan and not pickPlan then
                    for key in pairs(plan) do
                        -- plan keys are "enc:diff" strings; any difficulty counts
                        if tostring(key):find(enc .. ":", 1, true) == 1 then
                            pickPlan = enc
                            break
                        end
                    end
                end
                local ev = BossSimEV(enc, simKey, d, d)
                if ev and (not bestVal or ev > bestVal) then bestVal, pickBest = ev, enc end
            end
            local enc = pickPlan or pickBest or first
            if not enc then return false end
            EncounterJournal_DisplayEncounter(enc)
            local info = EncounterJournal and EncounterJournal.encounter and EncounterJournal.encounter.info
            if info and info.lootTab and info.lootTab.IsEnabled and info.lootTab:IsEnabled() then
                -- Blizzard's own OpenJournal does exactly this click for item links
                info.lootTab:Click()
            end
            return true
        end
        if not SelectBoss() then
            -- cold data: retry once it has streamed in (the tour step waits
            -- longer than this before measuring)
            C_Timer.After(0.25, SelectBoss)
        end
        return true
    end,
    CloseGuide = function()
        if tourGuideWasShown == false and EncounterJournal and EncounterJournal:IsShown() then
            HideUIPanel(EncounterJournal)
        end
        tourGuideWasShown = nil
    end,
    -- Ring target for the tour: the Arc info bar inside the guide. Ringing
    -- every scattered coin and value line read as clutter (Arc's call), so
    -- the bar is the one circled anchor and the callout text points at the
    -- rest.
    StripFrame = function()
        return ejStrip or nil
    end,
}
end
