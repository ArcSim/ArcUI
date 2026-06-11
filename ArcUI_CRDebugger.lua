--[[
ArcUI_CRDebugger.lua
Standalone charge-spell AND item debugger for ArcUI Cooldown Reminder.

SPELL MODE:
    /crdebug <spellID>        — track a spell
    Logs GetSpellCooldown + GetSpellCharges state, hooks Engine methods.

ITEM MODE:
    /crdebug item <itemID>    — track an item
    Logs GetInventoryItemCooldown / C_Container.GetItemCooldown state,
    use-spell isActive/isOnGCD, shadow widget IsShown(), and hooks
    Engine._FeedItemInvShadow / _EvaluateRecord / _OnTimerComplete /
    OnItemCooldownUpdate / OnItemReset so we can see EXACTLY what fires
    when, what state the shadow reports, and where delays come from.

OTHER:
    /crdebug stop             — stop tracking
    /crdebug show             — toggle log window
    /crdebug clear            — clear log
]]

-- Capture ArcUI addon namespace for Engine access.
local ADDON, ns = ...

local CRD = {}
local trackedMode      = nil    -- "spell" or "item"
local trackedSpellID   = nil
local trackedItemID    = nil
local trackedItemSlot  = nil    -- 13/14/nil
local trackedUseSpell  = nil    -- item's use-spell ID if any
local startTime        = nil
local logLines         = {}
local logFrame         = nil

local function T()
    if not startTime then return 0 end
    return GetTime() - startTime
end

local function TS()
    return string.format("[%07.3f]", T())
end

local function Log(tag, msg)
    -- Build line safely — all parts must be plain strings
    local ts  = TS()
    local ok1, tagStr = pcall(tostring, tag or "")
    local ok2, msgStr = pcall(tostring, msg or "")
    if not ok1 then tagStr = "<secret>" end
    if not ok2 then msgStr = "<secret>" end
    -- Extra guard: verify concat won't throw
    local line
    local ok3 = pcall(function()
        line = string.format("%s %-22s %s", ts, tagStr, msgStr)
    end)
    if not ok3 then line = string.format("[%07.3f] <log error>", ts) end
    logLines[#logLines + 1] = line
    if #logLines > 2000 then table.remove(logLines, 1) end
    if logFrame and logFrame:IsShown() then
        CRD.Refresh()
    end
end

local function SafeField(tbl, key)
    if not tbl then return "nil" end
    local ok, v = pcall(function() return tbl[key] end)
    if not ok then return "<secret>" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    local ok2, s = pcall(tostring, v)
    return (ok2 and s) or "<secret>"
end

local function StateStr(spellID)
    local ok1, cd = pcall(function()
        return C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    end)
    if not ok1 then cd = nil end

    local ok2, ch = pcall(function()
        return C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
    end)
    if not ok2 then ch = nil end

    local cdStr
    if cd then
        cdStr = string.format("isActive=%-7s isOnGCD=%-7s isEnabled=%-5s",
            SafeField(cd, "isActive"),
            SafeField(cd, "isOnGCD"),
            SafeField(cd, "isEnabled"))
    else
        cdStr = "isActive=nil    isOnGCD=nil     isEnabled=nil "
    end

    local chStr
    if ch then
        chStr = string.format("chargesActive=%-7s cur=%-3s max=%-3s",
            SafeField(ch, "isActive"),
            SafeField(ch, "currentCharges"),
            SafeField(ch, "maxCharges"))
    else
        chStr = "chargesActive=nil     cur=nil max=nil"
    end

    return cdStr .. "  " .. chStr
end

-- Build a verbose item-state string covering every API we care about:
-- INV numeric values, container fallback, use-spell flags, shadow IsShown().
local function ItemStateStr(itemID, slot, useSpell)
    -- INV path (equipped): GetInventoryItemCooldown
    local invStr
    if slot then
        local s, d = GetInventoryItemCooldown("player", slot)
        s = s or 0; d = d or 0
        local rem = (s > 0 and d > 0) and math.max(0, (s + d) - GetTime()) or 0
        invStr = string.format("INV[slot %d]: start=%.2f dur=%.2f rem=%.2f", slot, s, d, rem)
    else
        invStr = "INV[---]"
    end

    -- Container path (bag)
    local bagStr
    if C_Container and C_Container.GetItemCooldown then
        local s, d = C_Container.GetItemCooldown(itemID)
        s = s or 0; d = d or 0
        local rem = (s > 0 and d > 0) and math.max(0, (s + d) - GetTime()) or 0
        bagStr = string.format("BAG: start=%.2f dur=%.2f rem=%.2f", s, d, rem)
    else
        bagStr = "BAG[---]"
    end

    -- Use-spell flags (non-secret fields only)
    local usStr
    if useSpell and C_Spell and C_Spell.GetSpellCooldown then
        local ci = C_Spell.GetSpellCooldown(useSpell)
        if ci then
            usStr = string.format("useSpell[%d]: isActive=%s isOnGCD=%s isEnabled=%s",
                useSpell,
                SafeField(ci, "isActive"),
                SafeField(ci, "isOnGCD"),
                SafeField(ci, "isEnabled"))
        else
            usStr = string.format("useSpell[%d]: nil-info", useSpell)
        end
    else
        usStr = "useSpell[---]"
    end

    -- Shadow widget state from CR Engine, if record exists
    local shadowStr = "shadow[?]"
    local CR = ns and ns.CooldownReminder
    local Engine = CR and CR.Engine
    if Engine and Engine.records and Engine.records[itemID] then
        local rec = Engine.records[itemID]
        local cdShown = rec.cdWidget and rec.cdWidget:IsShown()
        shadowStr = string.format("shadow: cdShown=%s watchToken=%s _readyFired=%s _lastState=%s",
            tostring(cdShown), tostring(rec.watchToken),
            tostring(rec._readyPulseFired), tostring(rec._lastShadowState))
    end

    return string.format("%s | %s | %s | %s", invStr, bagStr, usStr, shadowStr)
end

-- ===================================================================
-- EVENT FRAME
-- ===================================================================
local ef = CreateFrame("Frame")
local registered = false

local function OnEvent(self, event, ...)
    if not trackedMode then return end

    -- ── SPELL MODE ────────────────────────────────────────────────────
    if trackedMode == "spell" and trackedSpellID then
        local sid = trackedSpellID

        if event == "SPELL_UPDATE_COOLDOWN" or event == "ACTIONBAR_UPDATE_COOLDOWN" then
            local a1,a2,a3,a4 = ...
            local isOurs = (a1 == sid) or (a2 == sid)
            local isGCD  = (a4 == 133)
            if not isOurs and not isGCD then return end
            local tag = isGCD and "SUC[GCD]" or "SPELL_CD"
            Log(tag, StateStr(sid) .. (isGCD and "  cat=0 rc=133" or ""))

        elseif event == "SPELL_UPDATE_CHARGES" then
            Log("CHARGES  ", StateStr(sid))

        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, _, spellID = ...
            if unit == "player" and spellID == sid then
                Log("* CAST_DONE", string.format("spellID=%d", spellID))
            end

        elseif event == "UNIT_SPELLCAST_START" then
            local unit, _, spellID = ...
            if unit == "player" and spellID == sid then
                Log("* CAST_START", string.format("spellID=%d", spellID))
            end
        end
        return
    end

    -- ── ITEM MODE ─────────────────────────────────────────────────────
    if trackedMode == "item" and trackedItemID then
        local itemID   = trackedItemID
        local slot     = trackedItemSlot
        local useSpell = trackedUseSpell

        if event == "BAG_UPDATE_COOLDOWN" then
            Log("BAG_CD  ", ItemStateStr(itemID, slot, useSpell))

        elseif event == "SPELL_UPDATE_COOLDOWN" then
            local a1, a2 = ...
            local isOurUseSpell = useSpell and ((a1 == useSpell) or (a2 == useSpell))
            local isBulkNil     = (a1 == nil)
            if not isOurUseSpell and not isBulkNil then return end
            local tag = isOurUseSpell and "SUC[useSpell]" or "SUC[nil-bulk]"
            Log(tag, ItemStateStr(itemID, slot, useSpell))

        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, _, spellID = ...
            if unit == "player" and useSpell and spellID == useSpell then
                Log("* CAST_DONE[useSpell]",
                    string.format("spellID=%d | %s", spellID, ItemStateStr(itemID, slot, useSpell)))
            end

        elseif event == "UNIT_SPELLCAST_START" then
            local unit, _, spellID = ...
            if unit == "player" and useSpell and spellID == useSpell then
                Log("* CAST_START[useSpell]", string.format("spellID=%d", spellID))
            end

        elseif event == "PLAYER_EQUIPED_SPELLS_CHANGED" then
            Log("EQUIPED_SPELLS", ItemStateStr(itemID, slot, useSpell))

        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            local changedSlot = ...
            -- Re-detect slot
            local newSlot = nil
            if GetInventoryItemID("player", 13) == itemID then newSlot = 13
            elseif GetInventoryItemID("player", 14) == itemID then newSlot = 14 end
            if newSlot ~= trackedItemSlot then
                Log("EQUIPMENT_CHANGED",
                    string.format("tracked item slot: %s → %s (event slot=%s)",
                        tostring(trackedItemSlot), tostring(newSlot), tostring(changedSlot)))
                trackedItemSlot = newSlot
            end

        elseif event == "ENCOUNTER_END"
            or event == "PLAYER_REGEN_ENABLED"
            or event == "CHALLENGE_MODE_START"
            or event == "CHALLENGE_MODE_RESET"
            or event == "ARENA_OPPONENT_UPDATE" then
            Log("RESET[" .. event .. "]", ItemStateStr(itemID, slot, useSpell))
        end
        return
    end
end

local function StartTrackingSpell(spellID)
    trackedMode     = "spell"
    trackedSpellID  = spellID
    trackedItemID   = nil
    trackedItemSlot = nil
    trackedUseSpell = nil
    startTime = GetTime()
    wipe(logLines)

    local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or tostring(spellID)
    local ch   = C_Spell.GetSpellCharges and (function()
        local ok,v = pcall(C_Spell.GetSpellCharges, spellID)
        return ok and v or nil
    end)()
    local maxC = ch and (function() local ok,v = pcall(function() return ch.maxCharges end); return ok and v or "?" end)() or "none"

    Log("START   ", string.format("spellID=%d  name=%s  [%s]",
        spellID, name, maxC ~= "none" and ("CHARGE SPELL maxCharges="..tostring(maxC)) or "COOLDOWN SPELL"))
    Log("LEGEND  ", "chargesActive=true=RECHARGING  false=FULL  isActive(cd)=true=ON_CD/GCD")
    Log("INITIAL ", StateStr(spellID))

    if not registered then
        ef:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        ef:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        ef:RegisterEvent("SPELL_UPDATE_CHARGES")
        ef:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        ef:RegisterEvent("UNIT_SPELLCAST_START")
        ef:SetScript("OnEvent", OnEvent)
        registered = true
    end

    -- Resolve the engine namespace ONCE, up front. Used for both the
    -- CR._debugTrace install AND the _EmitPulse/_StartWatching/_StopWatching
    -- hook installs below.
    local CR = ns and ns.CooldownReminder
    local Engine = CR and CR.Engine

    -- Install CR._debugTrace so the engine routes charge-detection traces
    -- (state transitions, pulse-fire, debounce, session-gate-suppressed) into
    -- this debugger's log window instead of chat.
    if CR and trackedSpellID then
        CR._debugTrace = function(tag, sID, msg)
            -- Allow sID==nil for global traces (e.g. CHARGE_EVENT branch reached).
            if sID ~= nil and sID ~= trackedSpellID then return end
            Log(tag, tostring(msg or ""))
        end
    end

    -- Hook Engine:_EmitPulse so we see WHICH code path actually fires the pulse,
    -- not just what the raw APIs return. Also hook _StartWatching and _StopWatching
    -- so we can see the session lifecycle.
    if Engine and not Engine.__arcCRDebugHooked then
        Engine.__arcCRDebugHooked = true

        -- Hook _EmitPulse: log every pulse attempt with spellID/kind/reason and
        -- whether it was suppressed by downstream gates (enabled/pulseEnabled/zone).
        local origEmit = Engine._EmitPulse
        Engine._EmitPulse = function(selfE, sID, kind, reason, isItem)
            if trackedSpellID and sID == trackedSpellID then
                Log("!! PULSE CALL",
                    string.format("spellID=%s kind=%s reason=%s  state: %s",
                        tostring(sID), tostring(kind), tostring(reason), StateStr(sID)))
                -- Mini stack trace to identify the calling path
                local trace = debugstack(2, 6, 0)
                if trace then
                    local shortTrace = trace:gsub("\n%s+", "\n    "):sub(1, 600)
                    Log("   STACK",  shortTrace)
                end
            end
            return origEmit(selfE, sID, kind, reason, isItem)
        end

        -- Hook session lifecycle so we can see when chargeSessionActive flips.
        local origStart = Engine._StartWatching
        Engine._StartWatching = function(selfE, rec, castSpellID)
            local sID = rec and rec.spellID
            local ret = origStart(selfE, rec, castSpellID)
            if trackedSpellID and sID == trackedSpellID then
                Log(">> _StartWatching",
                    string.format("castSpellID=%s chargeSessionActive=%s lastChargeRecharging=%s",
                        tostring(castSpellID),
                        tostring(rec and rec.chargeSessionActive),
                        tostring(rec and rec.lastChargeRecharging)))
            end
            return ret
        end
        local origStop = Engine._StopWatching
        Engine._StopWatching = function(selfE, rec, reason)
            local sID = rec and rec.spellID
            local wasActive = rec and rec.watchToken
            local ret = origStop(selfE, rec, reason)
            if trackedSpellID and sID == trackedSpellID and wasActive then
                Log("<< _StopWatching",
                    string.format("reason=%s chargeSessionActive=%s",
                        tostring(reason), tostring(rec and rec.chargeSessionActive)))
            end
            return ret
        end

        Log("HOOK    ", "Engine:_EmitPulse + _StartWatching + _StopWatching hooked")
    elseif not Engine then
        Log("HOOK ERR", "Could not find ArcUI Cooldown Reminder Engine to hook")
    end

    print(string.format("|cff00ccffArcUI CR Debug|r: Tracking spellID %d (%s). /crdebug show", spellID, name))
end

-- ── ITEM TRACKING ─────────────────────────────────────────────────────
local function StartTrackingItem(itemID)
    trackedMode     = "item"
    trackedSpellID  = nil
    trackedItemID   = itemID
    -- Detect equipped slot
    if GetInventoryItemID("player", 13) == itemID then
        trackedItemSlot = 13
    elseif GetInventoryItemID("player", 14) == itemID then
        trackedItemSlot = 14
    else
        trackedItemSlot = nil
    end
    -- Resolve use-spell
    local _, useSpell = GetItemSpell(itemID)
    trackedUseSpell = tonumber(useSpell) or nil
    startTime = GetTime()
    wipe(logLines)

    local itemName = GetItemInfo(itemID) or ("item:" .. tostring(itemID))
    local slotTag = trackedItemSlot
        and string.format(" [equipped slot %d]", trackedItemSlot)
        or  " [bag item]"
    local useTag = trackedUseSpell
        and string.format(" [useSpell=%d]", trackedUseSpell)
        or  " [passive — no use-spell]"

    Log("START   ", string.format("itemID=%d name=%s%s%s",
        itemID, itemName, slotTag, useTag))
    Log("LEGEND  ",
        "Watch for: delay between CAST_DONE → SHADOW_DONE_ITEM → PULSE CALL. " ..
        "FEED_ITEM events show what _FeedItemInvShadow pushes into the widget. " ..
        "EVAL_ITEM events show _EvaluateRecord's state read.")
    Log("INITIAL ", ItemStateStr(itemID, trackedItemSlot, trackedUseSpell))

    if not registered then
        ef:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        ef:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        ef:RegisterEvent("SPELL_UPDATE_CHARGES")
        ef:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        ef:RegisterEvent("UNIT_SPELLCAST_START")
        -- Item-mode events
        ef:RegisterEvent("BAG_UPDATE_COOLDOWN")
        ef:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        ef:RegisterEvent("PLAYER_EQUIPED_SPELLS_CHANGED")
        ef:RegisterEvent("ENCOUNTER_END")
        ef:RegisterEvent("PLAYER_REGEN_ENABLED")
        ef:RegisterEvent("CHALLENGE_MODE_START")
        ef:RegisterEvent("CHALLENGE_MODE_RESET")
        ef:RegisterEvent("ARENA_OPPONENT_UPDATE")
        ef:SetScript("OnEvent", OnEvent)
        registered = true
    end

    local CR = ns and ns.CooldownReminder
    local Engine = CR and CR.Engine

    -- Install debug-trace route
    if CR then
        CR._debugTrace = function(tag, sID, msg)
            if sID ~= nil and sID ~= itemID then return end
            Log(tag, tostring(msg or ""))
        end
    end

    -- Hook the item-path methods so we see EXACTLY what happens at each step.
    -- Track separate hook flag so spell-only and item-extra hooks coexist.
    if Engine and not Engine.__arcCRDebugItemHooked then
        Engine.__arcCRDebugItemHooked = true

        -- _FeedItemInvShadow: shows exactly what we're pushing into the widget
        if Engine._FeedItemInvShadow or CR._FeedItemInvShadow then
            local origFeed = CR._FeedItemInvShadow
            if origFeed then
                CR._FeedItemInvShadow = function(rec)
                    local ret = origFeed(rec)
                    if trackedItemID and rec and rec.itemID == trackedItemID then
                        local cdShown = rec.cdWidget and rec.cdWidget:IsShown()
                        Log("FEED_ITEM",
                            string.format("slot=%s → cdShown=%s | %s",
                                tostring(rec._equippedSlot), tostring(cdShown),
                                ItemStateStr(trackedItemID, trackedItemSlot, trackedUseSpell)))
                    end
                    return ret
                end
            end
        end

        -- _EvaluateRecord: shows when the engine re-evaluates an item and the
        -- state transition decision.
        local origEval = Engine._EvaluateRecord
        Engine._EvaluateRecord = function(selfE, rec, source, skipFeed)
            local isOurs = trackedItemID and rec and rec.isItem and rec.itemID == trackedItemID
            local preShown = isOurs and rec.cdWidget and rec.cdWidget:IsShown()
            local preLast  = isOurs and rec._lastShadowState
            local ret = origEval(selfE, rec, source, skipFeed)
            if isOurs then
                local postShown = rec.cdWidget and rec.cdWidget:IsShown()
                local postLast  = rec._lastShadowState
                Log("EVAL_ITEM",
                    string.format("src=%s  cdShown: %s→%s  state: %s→%s  watchToken=%s  readyFired=%s",
                        tostring(source), tostring(preShown), tostring(postShown),
                        tostring(preLast), tostring(postLast),
                        tostring(rec.watchToken), tostring(rec._readyPulseFired)))
            end
            return ret
        end

        -- _OnTimerComplete: the widget's OnCooldownDone fired.
        local origOnTimer = Engine._OnTimerComplete
        Engine._OnTimerComplete = function(selfE, widget)
            local rec = widget and widget._rec
            local isOurs = trackedItemID and rec and rec.isItem and rec.itemID == trackedItemID
            if isOurs then
                Log("SHADOW_DONE_ITEM",
                    string.format("kind=%s | %s",
                        tostring(widget._kind),
                        ItemStateStr(trackedItemID, trackedItemSlot, trackedUseSpell)))
            end
            return origOnTimer(selfE, widget)
        end

        -- OnItemCooldownUpdate: engine handler for BAG_UPDATE_COOLDOWN
        local origItemCD = Engine.OnItemCooldownUpdate
        Engine.OnItemCooldownUpdate = function(selfE)
            if trackedItemID then
                Log("→ OnItemCooldownUpdate",
                    ItemStateStr(trackedItemID, trackedItemSlot, trackedUseSpell))
            end
            return origItemCD(selfE)
        end

        -- OnItemReset: engine handler for the reset events
        if Engine.OnItemReset then
            local origReset = Engine.OnItemReset
            Engine.OnItemReset = function(selfE, event)
                if trackedItemID then
                    Log("→ OnItemReset[" .. tostring(event) .. "]",
                        ItemStateStr(trackedItemID, trackedItemSlot, trackedUseSpell))
                end
                return origReset(selfE, event)
            end
        end

        Log("HOOK    ", "Item-path engine methods hooked (feed/eval/timer/bagupdate/reset)")
    elseif not Engine then
        Log("HOOK ERR", "Could not find ArcUI Cooldown Reminder Engine to hook")
    end

    -- Also install _EmitPulse hook so we see when pulse actually fires
    if Engine and not Engine.__arcCRDebugHooked then
        Engine.__arcCRDebugHooked = true
        local origEmit = Engine._EmitPulse
        Engine._EmitPulse = function(selfE, sID, kind, reason, isItem)
            if trackedItemID and isItem and sID == trackedItemID then
                Log("!! PULSE CALL",
                    string.format("itemID=%s kind=%s reason=%s | %s",
                        tostring(sID), tostring(kind), tostring(reason),
                        ItemStateStr(trackedItemID, trackedItemSlot, trackedUseSpell)))
                local trace = debugstack(2, 6, 0)
                if trace then
                    local shortTrace = trace:gsub("\n%s+", "\n    "):sub(1, 600)
                    Log("   STACK", shortTrace)
                end
            elseif trackedSpellID and sID == trackedSpellID then
                Log("!! PULSE CALL",
                    string.format("spellID=%s kind=%s reason=%s  state: %s",
                        tostring(sID), tostring(kind), tostring(reason), StateStr(sID)))
            end
            return origEmit(selfE, sID, kind, reason, isItem)
        end

        local origStart = Engine._StartWatching
        Engine._StartWatching = function(selfE, rec, castSpellID)
            local sID = rec and rec.spellID
            local ret = origStart(selfE, rec, castSpellID)
            local isOurItem = trackedItemID and rec and rec.isItem and rec.itemID == trackedItemID
            local isOurSpell = trackedSpellID and sID == trackedSpellID
            if isOurItem or isOurSpell then
                Log(">> _StartWatching",
                    string.format("id=%s watchToken=%s",
                        tostring(sID), tostring(rec and rec.watchToken)))
            end
            return ret
        end
        local origStop = Engine._StopWatching
        Engine._StopWatching = function(selfE, rec, reason)
            local sID = rec and rec.spellID
            local wasActive = rec and rec.watchToken
            local isOurItem = trackedItemID and rec and rec.isItem and rec.itemID == trackedItemID
            local isOurSpell = trackedSpellID and sID == trackedSpellID
            local ret = origStop(selfE, rec, reason)
            if (isOurItem or isOurSpell) and wasActive then
                Log("<< _StopWatching",
                    string.format("id=%s reason=%s", tostring(sID), tostring(reason)))
            end
            return ret
        end
    end

    print(string.format("|cff00ccffArcUI CR Debug|r: Tracking itemID %d (%s)%s. /crdebug show",
        itemID, itemName, slotTag))
end

local function StopTracking()
    trackedMode     = nil
    trackedSpellID  = nil
    trackedItemID   = nil
    trackedItemSlot = nil
    trackedUseSpell = nil
    -- Uninstall engine trace route.
    local CR = ns and ns.CooldownReminder
    if CR then CR._debugTrace = nil end
    print("|cff00ccffArcUI CR Debug|r: Stopped.")
end

-- ===================================================================
-- LOG WINDOW
-- ===================================================================
local function EnsureFrame()
    if logFrame then return end
    local f = CreateFrame("Frame", "ArcUICRDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(900, 520)
    f:SetPoint("CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=14,
        insets={left=3,right=3,top=3,bottom=3},
    })
    f:SetBackdropColor(0.04, 0.04, 0.04, 0.96)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("|cff00ccffArcUI CR Debugger|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 22)
    clearBtn:SetPoint("TOPRIGHT", -36, -8)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        wipe(logLines)
        CRD.Refresh()
    end)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -34)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetWidth(855)
    edit:SetAutoFocus(false)
    edit:EnableMouse(true)
    scroll:SetScrollChild(edit)

    f._edit   = edit
    f._scroll = scroll
    f:Hide()
    logFrame = f

    function CRD.Refresh()
        if not logFrame then return end
        -- table.concat crashes on secret values — build manually
        local safeLines = {}
        for i, ln in ipairs(logLines) do
            local ok, s = pcall(tostring, ln)
            safeLines[i] = ok and s or "<secret line>"
        end
        local ok, txt = pcall(table.concat, safeLines, "\n")
        logFrame._edit:SetText(ok and txt or "<error building log>")
        C_Timer.After(0, function()
            if logFrame and logFrame._scroll then
                local sb = logFrame._scroll.ScrollBar
                if sb then
                    local _, mx = sb:GetMinMaxValues()
                    sb:SetValue(mx)
                end
            end
        end)
    end
end

-- ===================================================================
-- SLASH COMMAND
-- ===================================================================
SLASH_CRDEBUG1 = "/crdebug"
SlashCmdList["CRDEBUG"] = function(msg)
    msg = msg and msg:match("^%s*(.-)%s*$") or ""
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "stop" then
        StopTracking()
    elseif cmd == "show" then
        EnsureFrame()
        if logFrame:IsShown() then
            logFrame:Hide()
        else
            logFrame:Show()
            CRD.Refresh()
        end
    elseif cmd == "clear" then
        wipe(logLines)
        if logFrame then CRD.Refresh() end
        print("|cff00ccffArcUI CR Debug|r: Cleared.")
    elseif cmd == "item" then
        -- /crdebug item <itemID> or /crdebug item [item link]
        local itemID = tonumber(rest)
        if not itemID and type(rest) == "string" then
            itemID = tonumber(rest:match("item:(%d+)"))
        end
        if itemID then
            StartTrackingItem(itemID)
            EnsureFrame()
            logFrame:Show()
            CRD.Refresh()
        else
            print("|cff00ccffArcUI CR Debug|r: /crdebug item <itemID>   (or paste item link)")
        end
    else
        -- Default: spell ID
        local spellID = tonumber(cmd) or tonumber(rest)
        if spellID then
            StartTrackingSpell(spellID)
            EnsureFrame()
            logFrame:Show()
            CRD.Refresh()
        else
            print("|cff00ccffArcUI CR Debug|r: /crdebug <spellID> | item <itemID> | stop | show | clear")
        end
    end
end