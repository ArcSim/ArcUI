local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Kick Assist (ArcUI built-in module)
--
-- Same feature as the standalone "SetMyKick" addon: pick your interrupt (kick)
-- raid marker, announce it, and keep your interrupt macro's marker in sync.
--
-- Conflict guard: if the standalone SetMyKick addon is also loaded, this module
-- stays DORMANT (no frames, no events, no slash) so nothing doubles up. The
-- options tab then just points the user at the standalone. Disable the standalone
-- addon to use this built-in version.
--
-- Marking note: SetRaidTarget is PROTECTED; the marking lives in the user's macro
-- via the game's built-in secure /tm. This module only rewrites the marker number.
--------------------------------------------------------------------------------

ns.SetMyKick = ns.SetMyKick or {}
local SMK = ns.SetMyKick

-- {interrupt} = your spec's interrupt, {marker} = your marker. Marking is always on
-- @focus, and the ~ before {marker} marks only if your focus has no marker yet, so the
-- marker is placed when you set your focus and then stays put: re-pressing kicks the
-- focus and never moves the marker onto whatever you happen to be targeting. The
-- default Focus+Kick casts before setting focus, so the first press sets focus and the
-- next press kicks it (no modifier, no mouseover).
local DEFAULT_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cast [@focus,harm,nodead] {interrupt}\n" ..
	"/focus [@focus,noexists] target\n" ..
	"/tm [@focus] ~{marker}"

-- Set focus + mark; no #showtooltip so it keeps the targeting icon.
local SET_FOCUS_MACRO =
	"/focus target\n" ..
	"/tm [@focus] ~{marker}"

-- Auto tab kick (default): tab to the nearest enemy, interrupt, return to your target.
local AUTOTAB_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/targetlasttarget"

-- Auto tab kick (focus first): kick your focus if you have one, else tab-interrupt
-- a casting mob without losing your current target.
local AUTOTAB_FOCUS_MACRO =
	"#showtooltip {interrupt}\n" ..
	"/cast [@focus,exists,nodead,harm] {interrupt}\n" ..
	"/stopmacro [@focus,exists,nodead,harm]\n" ..
	"/focus target\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/target focus\n" ..
	"/clearfocus\n" ..
	"/startattack"

-- Auto tab kick (mouseover override): kick your mouseover or focus if valid, else
-- tab-interrupt without losing your current target.
local AUTOTAB_MOUSEOVER_MACRO =
	"#showtooltip\n" ..
	"/cast [@mouseover,harm,nodead][@focus,harm,nodead,exists] {interrupt}\n" ..
	"/stopmacro [@mouseover,harm,nodead][@focus,harm,nodead,exists]\n" ..
	"/focus target\n" ..
	"/cleartarget\n" ..
	"/targetenemy\n" ..
	"/cast {interrupt}\n" ..
	"/target focus\n" ..
	"/clearfocus"

-- Templates per macro slot: the editor shows the set for whichever macro is selected.
local TEMPLATES = {
	kick = {
		{ name = "Focus + Kick (default, re-press to kick)", body = DEFAULT_MACRO },
		{ name = "Focus + Kick (Ctrl to kick your target)",
		  body = "#showtooltip {interrupt}\n/cast [nomod:ctrl,@focus,harm,nodead][] {interrupt}\n/focus [@focus,noexists] target\n/tm [@focus] ~{marker}" },
		{ name = "Focus + Kick (mouseover)",
		  body = "#showtooltip {interrupt}\n/cast [@focus,harm,nodead] {interrupt}\n/focus [@mouseover,harm,nodead,exists] mouseover\n/tm [@focus] ~{marker}" },
	},
	focus = {
		{ name = "Set focus (target)", body = SET_FOCUS_MACRO },
		{ name = "Set focus (mouseover)",
		  body = "/focus [@mouseover,exists] mouseover\n/tm [@focus] ~{marker}" },
	},
	autotab = {
		{ name = "Auto Tab Kick (tab to nearest)", body = AUTOTAB_MACRO },
		{ name = "Auto Tab Kick (focus first, else tab)", body = AUTOTAB_FOCUS_MACRO },
		{ name = "Auto Tab Kick (mouseover or focus, else tab)", body = AUTOTAB_MOUSEOVER_MACRO },
	},
}

-- The three macro slots the editor can edit (Focus+Kick, Set Focus, Auto Tab Kick).
local SLOT_CFG = {
	kick    = { label = "Focus + Kick",  nameKey = "macroName",    tmplKey = "macroTemplate",    defName = "FocusKick",   defBody = DEFAULT_MACRO },
	focus   = { label = "Set Focus",     nameKey = "setFocusName", tmplKey = "setFocusTemplate", defName = "SetFocus",    defBody = SET_FOCUS_MACRO },
	autotab = { label = "Auto Tab Kick", nameKey = "autoTabName",  tmplKey = "autoTabTemplate",  defName = "AutoTabKick", defBody = AUTOTAB_MACRO },
}
local SLOT_ORDER = { "kick", "focus", "autotab" }

local DEFAULTS = {
	-- NOTE: `enabled` is account-wide and lives in ns.db.global.setMyKick (see EnsureDB),
	-- not here, so it is not recreated per-character.
	marker           = 8,
	showOnReadyCheck = true,
	announceOnReadyCheck = true,         -- post your kick to chat on a ready check (sends before a key; auto-skips once chat is locked)
	-- Which instances the ready-check popup/announce fires in (default: Mythic dungeons only).
	contexts         = { mplus = true, mythic = true, heroic = false, normal = false, raid = false },
	smartOpen        = false,            -- on a ready check, wait and open only if someone else calls your marker
	message          = "My Focus Kick is %MARKER%",
	macroEnabled     = false,
	macroName        = "FocusKick",      -- set-focus-and-kick macro
	macroTemplate    = DEFAULT_MACRO,
	setFocusName     = "SetFocus",       -- set-focus-and-mark macro
	setFocusTemplate = SET_FOCUS_MACRO,
	autoTabName      = "AutoTabKick",    -- auto tab-interrupt macro
	autoTabTemplate  = AUTOTAB_MACRO,
	point            = { "CENTER", "CENTER", 0, 140 },
	macroPoint       = { "CENTER", "CENTER", 0, 0 },
}

local MARKER_NAMES = {
	[0] = "No Marker",
	"Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull",
}

local PREFIX = "|cff33ff99Kick Assist|r: "
local FOCUS_ICON = 132212  -- set-focus macro icon (fileID)

-- Interrupt spell per class, spec overrides keyed by specialization ID.
local INTERRUPTS = {
	DEATHKNIGHT = { default = 47528  },
	DEMONHUNTER = { default = 183752 },
	DRUID       = { default = 106839, [102] = 78675  },
	EVOKER      = { default = 351338 },
	HUNTER      = { default = 147362, [255] = 187707 },
	MAGE        = { default = 2139   },
	MONK        = { default = 116705 },
	PALADIN     = { default = 96231  },
	PRIEST      = {                   [258] = 15487 },
	ROGUE       = { default = 1766   },
	SHAMAN      = { default = 57994  },
	WARLOCK     = { default = 19647  },
	WARRIOR     = { default = 6552   },
}

local DB        -- ns.db.char.setMyKick (per-character settings), resolved lazily
local GDB       -- ns.db.global.setMyKick (account-wide: the enable flag)
local frame     -- popup
local macroFrame
local eventFrame
local slashRegistered = false
local myName             -- our character name, cached while readable (UnitName is secret inside M+)
local smartOpenExpire = 0  -- GetTime() until which Smart Open watches party chat

-- Cache our own name while it is readable. UnitName("player") is secret inside instances,
-- so we grab it on login / zoning and reuse that string to recognize our own chat echo.
local function RememberMyName()
	local n = UnitName("player")
	if n and not issecretvalue(n) then myName = n end
end

-- Marker index -> spoken token names, so Smart Open also catches manual callouts.
local MARKER_TOKENS = {
	[1] = { "star" }, [2] = { "circle", "coin" }, [3] = { "diamond" }, [4] = { "triangle" },
	[5] = { "moon" }, [6] = { "square" }, [7] = { "cross", "x" }, [8] = { "skull" },
}

-- Does an incoming chat message call out YOUR marker? Matches {rtN}, the named token
-- ({skull} etc.) and the rendered icon escape. Pure string parsing, so taint-safe in M+.
local function MessageCallsMyMarker(text)
	local m = DB and DB.marker
	if not text or issecretvalue(text) or not m or m < 1 or m > 8 then return false end
	text = text:lower()
	if text:find("{rt" .. m .. "}", 1, true) then return true end
	if text:find("raidtargetingicon_" .. m, 1, true) then return true end
	for _, name in ipairs(MARKER_TOKENS[m]) do
		if text:find("{" .. name .. "}", 1, true) then return true end
	end
	return false
end

-- Smart Open watcher: for a brief window after a ready check, watch party/raid chat; if
-- someone ELSE calls out your marker, open the picker so you can change your focus. Chat
-- text is non-secret, so this stays taint-safe in M+ (unlike reading raid markers off units).
local SMART_OPEN_WINDOW = 4
local SMART_CHAT_EVENTS = {
	"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID",
	"CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
}
local function DisarmSmartOpen()
	smartOpenExpire = 0
	if eventFrame then
		for _, e in ipairs(SMART_CHAT_EVENTS) do eventFrame:UnregisterEvent(e) end
	end
end
local function ArmSmartOpen()
	if not eventFrame then return end
	smartOpenExpire = GetTime() + SMART_OPEN_WINDOW
	for _, e in ipairs(SMART_CHAT_EVENTS) do eventFrame:RegisterEvent(e) end
	C_Timer.After(SMART_OPEN_WINDOW + 0.1, function()
		if GetTime() >= smartOpenExpire then DisarmSmartOpen() end
	end)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function IsStandaloneLoaded()
	return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("KickAssist")
end

local function EnsureDB()
	if DB then return DB end
	if not ns.db then return nil end
	ns.db.char.setMyKick = ns.db.char.setMyKick or {}
	DB = ns.db.char.setMyKick
	for k, v in pairs(DEFAULTS) do
		if DB[k] == nil then
			DB[k] = (type(v) == "table") and CopyTable(v) or v
		end
	end
	-- The enable flag is ACCOUNT-WIDE; everything else stays per-character. Migrate a
	-- legacy per-character value to the account store once, then default on.
	ns.db.global.setMyKick = ns.db.global.setMyKick or {}
	GDB = ns.db.global.setMyKick
	if GDB.enabled == nil then
		if DB.enabled ~= nil then GDB.enabled = DB.enabled else GDB.enabled = true end
	end
	DB.enabled = nil
	return DB
end

local function ChatToken(index)
	if index and index >= 1 and index <= 8 then
		return "{rt" .. index .. "}"
	end
	return "no marker"
end

local function SetMarkerTexture(tex, index)
	tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	local col  = (index - 1) % 4
	local row  = math.floor((index - 1) / 4)
	local left = col * 0.25
	local top  = row * 0.25
	tex:SetTexCoord(left, left + 0.25, top, top + 0.25)
end

local function GroupChannel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid() then return "RAID" end
	if IsInGroup() then return "PARTY" end
	return nil
end

-- Trigger contexts. Difficulty IDs: 1 Normal, 2 Heroic, 23 Mythic, 8 M+; raids via instanceType.
local CONTEXT_DEFAULTS = { mplus = true, mythic = true, heroic = false, normal = false, raid = false }
local CONTEXT_VALUES   = {
	mplus  = "Mythic+ (keystone)",
	mythic = "Mythic dungeon",
	heroic = "Heroic dungeon",
	normal = "Normal dungeon",
	raid   = "Raids",
}

local function CurrentContextKey()
	local inInstance, instanceType = IsInInstance()
	if not inInstance then return nil end
	if instanceType == "raid" then return "raid" end
	if instanceType == "party" then
		local diff = select(3, GetInstanceInfo())
		if diff == 8  then return "mplus"  end
		if diff == 23 then return "mythic" end
		if diff == 2  then return "heroic" end
		if diff == 1  then return "normal" end
	end
	return nil
end

local function ContextEnabled(key)
	local v = DB.contexts and DB.contexts[key]
	if v == nil then v = CONTEXT_DEFAULTS[key] end
	return v and true or false
end

local function ShouldTriggerHere()
	local key = CurrentContextKey()
	return key ~= nil and ContextEnabled(key)
end

-- True when addons may post to chat right now. The Chat restriction
-- (Enum.AddOnRestrictionType.Chat) is OFF before a Mythic+ key starts and flips
-- ON once the key is active, where an addon SendChatMessage is blocked. Checking
-- it lets the ready-check announce go out before the key and stand down after it,
-- with no blocked-action error. C_RestrictedActions is 12.0+; guarded for safety.
local function ChatAllowed()
	local C = C_RestrictedActions
	if C and C.IsAddOnRestrictionActive and Enum and Enum.AddOnRestrictionType then
		return not C.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat)
	end
	return true
end

local function GetMyInterruptID()
	local _, classToken = UnitClass("player")
	local data = classToken and INTERRUPTS[classToken]
	if not data then return nil end
	local specIndex = GetSpecialization()
	local specID = specIndex and GetSpecializationInfo(specIndex)
	return (specID and data[specID]) or data.default
end

local function GetMyInterruptName()
	local id = GetMyInterruptID()
	return id and C_Spell.GetSpellName(id) or nil
end

-- `fromTrigger` = fired by an event (e.g. the ready check) rather than a click; on
-- a trigger we stay silent when we can't send. We never send while chat is locked
-- (an active Mythic+ key), so this never throws a blocked-action error -- whether
-- called from a click or the ready-check trigger.
local function Announce(fromTrigger)
	if not EnsureDB() then return end
	local token   = ChatToken(DB.marker)
	local msg     = (tostring(DB.message or DEFAULTS.message):gsub("%%MARKER%%", token))
	local channel = GroupChannel()
	if not channel then
		if not fromTrigger then print(PREFIX .. msg .. " (not in a group, shown locally)") end
		return
	end
	if not ChatAllowed() then
		if not fromTrigger then print(PREFIX .. "chat is locked right now (Mythic+ in progress); announce skipped.") end
		return
	end
	SendChatMessage(msg, channel)
end

-- Swap marker numbers (0-8) that are real /tm arguments for a replacement, while
-- leaving any digits inside [condition] brackets alone. Returns the new string and
-- the number of markers replaced.
local function ReplaceTmMarkers(s, replacement)
	local out, depth, count = {}, 0, 0
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "[" then
			depth = depth + 1; out[#out + 1] = c
		elseif c == "]" then
			if depth > 0 then depth = depth - 1 end
			out[#out + 1] = c
		elseif depth == 0 and c >= "0" and c <= "8" then
			out[#out + 1] = replacement; count = count + 1
		else
			out[#out + 1] = c
		end
	end
	return table.concat(out), count
end

-- Make an existing macro body marker-managed for the "pick existing macro" flow:
-- in its first /tm line swap the marker number(s) for {marker} (adding ~{marker} if that
-- line has no number yet); if there is no /tm line at all, append one. Everything
-- else in the macro is left exactly as the player wrote it.
local function ManageMarkerInBody(body)
	body = tostring(body or ""):gsub("[\r\n]+$", "")
	if body == "" then return "/tm [@focus] ~{marker}" end
	local lines, handled = {}, false
	for line in (body .. "\n"):gmatch("(.-)\n") do
		if not handled then
			local prefix, rest = line:match("^(%s*/[tT][mM])(.*)$")
			if prefix and (rest == "" or rest:match("^[%s%[~!0-8]")) then
				local newRest, n = ReplaceTmMarkers(rest, "{marker}")
				line = prefix .. newRest
				if n == 0 then line = line .. " ~{marker}" end
				handled = true
			end
		end
		lines[#lines + 1] = line
	end
	if not handled then
		lines[#lines + 1] = "/tm [@focus] ~{marker}"
	end
	return table.concat(lines, "\n")
end

local function UpdateManagedMacro()
	if not EnsureDB() then return end
	if not GDB.enabled then return end
	if not DB.macroEnabled then return end
	if InCombatLockdown() then return end
	local name = DB.macroName ~= "" and DB.macroName or DEFAULTS.macroName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.macroTemplate or DEFAULT_MACRO)
	body = body:gsub("{interrupt}", interrupt):gsub("{marker}", tostring(DB.marker)):gsub("{kick}", tostring(DB.marker))
	if body == "" then return end
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, "INV_Misc_QuestionMark", body)
	else
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, "INV_Misc_QuestionMark", body, true)
	end
end

-- The fixed "set focus + mark" macro. Synced if it exists; created when create=true.
local function UpdateSetFocusMacro(create)
	if not (DB and GDB.enabled) then return end
	if InCombatLockdown() then return end
	local name = DB.setFocusName ~= "" and DB.setFocusName or DEFAULTS.setFocusName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.setFocusTemplate or SET_FOCUS_MACRO):gsub("{interrupt}", interrupt):gsub("{marker}", tostring(DB.marker)):gsub("{kick}", tostring(DB.marker))
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, FOCUS_ICON, body)
	elseif create then
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, FOCUS_ICON, body, true)
	end
end

-- The auto-tab-interrupt macro. Synced if it exists; created when create=true.
local function UpdateAutoTabMacro(create)
	if not (DB and GDB.enabled) then return end
	if InCombatLockdown() then return end
	local name = DB.autoTabName ~= "" and DB.autoTabName or DEFAULTS.autoTabName
	local interrupt = GetMyInterruptName() or ""
	local body = tostring(DB.autoTabTemplate or AUTOTAB_MACRO):gsub("{interrupt}", interrupt):gsub("{marker}", tostring(DB.marker)):gsub("{kick}", tostring(DB.marker))
	local idx = GetMacroIndexByName(name)
	if idx and idx > 0 then
		EditMacro(idx, name, "INV_Misc_QuestionMark", body)
	elseif create then
		local _, numChar = GetNumMacros()
		if numChar and numChar >= MAX_CHARACTER_MACROS then
			print(PREFIX .. "no free character macro slots for '" .. name .. "'.")
			return
		end
		CreateMacro(name, "INV_Misc_QuestionMark", body, true)
	end
end

-- Keep all managed macros in sync with the chosen marker; only edits ones that exist.
local function SyncMacros()
	UpdateManagedMacro()
	UpdateSetFocusMacro(false)
	UpdateAutoTabMacro(false)
end

--------------------------------------------------------------------------------
-- Popup UI
--------------------------------------------------------------------------------

local function UpdateSelection()
	if not frame then return end
	for i = 1, 8 do
		frame.markerButtons[i].sel:SetShown(DB.marker == i)
	end
	frame.noneButton.sel:SetShown(DB.marker == 0)
end

local function MakeSelTexture(parent)
	local t = parent:CreateTexture(nil, "OVERLAY")
	t:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	t:SetBlendMode("ADD")
	t:SetPoint("TOPLEFT", -3, 3)
	t:SetPoint("BOTTOMRIGHT", 3, -3)
	t:Hide()
	return t
end

local function MakeCheck(parent, label, x, y, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)
	cb.Refresh = function(self) self:SetChecked(get() and true or false) end
	return cb
end

local function RefreshDragIcons()
	if not frame or not frame.dragIcons then return end
	local id = GetMyInterruptID()
	local spellTex = (id and C_Spell.GetSpellTexture(id)) or 134400
	if frame.dragIcons.kick then
		frame.dragIcons.kick:SetTexture(spellTex)
		frame.dragIcons.kick:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	if frame.dragIcons.autotab then
		frame.dragIcons.autotab:SetTexture(spellTex)
		frame.dragIcons.autotab:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	if frame.dragIcons.focus then
		if type(FOCUS_ICON) == "number" then
			frame.dragIcons.focus:SetTexture(FOCUS_ICON)
		else
			frame.dragIcons.focus:SetTexture("Interface\\Icons\\" .. FOCUS_ICON)
		end
		frame.dragIcons.focus:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
end

local function CreateUI()
	if frame then return frame end
	EnsureDB()

	frame = CreateFrame("Frame", "ArcUI_SetMyKickFrame", UIParent, "BackdropTemplate")
	frame:SetSize(300, 476)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.04, 0.9)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, _, rp, x, y = self:GetPoint()
		DB.point = { p, rp, x, y }
	end)
	tinsert(UISpecialFrames, "ArcUI_SetMyKickFrame")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Kick Assist")

	local instr = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	instr:SetPoint("TOP", title, "BOTTOM", 0, -6)
	instr:SetText("Pick your kick marker")

	frame.markerButtons = {}
	for i = 1, 8 do
		local btn = CreateFrame("Button", nil, frame)
		btn:SetSize(40, 40)
		local col = (i - 1) % 4
		local row = math.floor((i - 1) / 4)
		btn:SetPoint("TOPLEFT", 55 + col * 50, -58 - row * 50)

		local icon = btn:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints()
		SetMarkerTexture(icon, i)

		btn.sel = MakeSelTexture(btn)
		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		btn:SetScript("OnClick", function()
			DB.marker = i
			UpdateSelection()
			RefreshDragIcons()
			SyncMacros()
			Announce()
		end)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(MARKER_NAMES[i])
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", GameTooltip_Hide)
		frame.markerButtons[i] = btn
	end

	local none = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	none:SetSize(100, 22)
	none:SetPoint("TOP", 0, -162)
	none:SetText("No Marker")
	none.sel = MakeSelTexture(none)
	none:SetScript("OnClick", function()
		DB.marker = 0
		UpdateSelection()
		RefreshDragIcons()
		SyncMacros()
	end)
	frame.noneButton = none

	frame.readyCB = MakeCheck(frame, "Show on ready check (in Mythic+)", 22, -196,
		function() return DB.showOnReadyCheck end,
		function(v) DB.showOnReadyCheck = v end)

	frame.smartCB = MakeCheck(frame, "Smart open (only on a marker clash)", 22, -220,
		function() return DB.smartOpen end,
		function(v) DB.smartOpen = v end)

	frame.announceCB = MakeCheck(frame, "Announce on ready check", 22, -244,
		function() return DB.announceOnReadyCheck end,
		function(v) DB.announceOnReadyCheck = v end)

	local msgLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	msgLabel:SetPoint("TOPLEFT", 22, -274)
	msgLabel:SetText("Message (%MARKER% = your icon):")

	local msgBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	msgBox:SetSize(246, 20)
	msgBox:SetPoint("TOPLEFT", 28, -292)
	msgBox:SetAutoFocus(false)
	msgBox:SetText(DB.message or DEFAULTS.message)
	msgBox:SetScript("OnEscapePressed", msgBox.ClearFocus)
	msgBox:SetScript("OnEnterPressed", function(self)
		DB.message = self:GetText()
		self:ClearFocus()
	end)
	msgBox:SetScript("OnEditFocusLost", function(self) DB.message = self:GetText() end)
	frame.msgBox = msgBox

	local announce = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	announce:SetSize(170, 26)
	announce:SetPoint("TOP", 0, -324)
	announce:SetText("Announce to Group")
	announce:SetScript("OnClick", function()
		DB.message = msgBox:GetText()
		Announce()
	end)

	local macroBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	macroBtn:SetSize(170, 24)
	macroBtn:SetPoint("TOP", 0, -358)
	macroBtn:SetText("Edit Macro...")
	macroBtn:SetScript("OnClick", function() SMK.ShowMacroEditor() end)

	-- Drag-to-bars: two ready macros new users can drop straight onto their bars.
	local dragHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dragHeader:SetPoint("TOP", 0, -384)
	dragHeader:SetText("New? Drag a macro to your action bar:")

	frame.dragIcons = {}

	local function PickupSlot(nameKey, defName, updateFn)
		if InCombatLockdown() then return end
		local name = (DB[nameKey] and DB[nameKey] ~= "") and DB[nameKey] or defName
		updateFn(true)
		local idx = GetMacroIndexByName(name)
		if idx and idx > 0 then PickupMacro(idx) end
	end

	local function MakeDragBox(xOff, labelText, desc, key, pickup)
		local box = CreateFrame("Button", nil, frame, "BackdropTemplate")
		box:SetSize(40, 40)
		box:SetPoint("TOP", xOff, -402)
		box:RegisterForDrag("LeftButton")
		box:RegisterForClicks("LeftButtonUp")
		box:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
		box:SetBackdropBorderColor(1, 0.82, 0, 0.9)
		local ic = box:CreateTexture(nil, "ARTWORK")
		ic:SetPoint("TOPLEFT", 2, -2)
		ic:SetPoint("BOTTOMRIGHT", -2, 2)
		box:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		frame.dragIcons[key] = ic
		box:SetScript("OnDragStart", pickup)
		box:SetScript("OnClick", pickup)
		box:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(labelText)
			GameTooltip:AddLine(desc, 1, 1, 1, true)
			GameTooltip:AddLine("Drag onto an action bar, or click then a bar slot.", 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", GameTooltip_Hide)
		local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		lbl:SetPoint("TOP", box, "BOTTOM", 0, -4)
		lbl:SetText(labelText)
		return box
	end

	MakeDragBox(-78, "Focus + Kick", "Interrupts your focus. First press focuses your target, then re-press to kick.", "kick", function()
		DB.macroEnabled = true
		PickupSlot("macroName", DEFAULTS.macroName, UpdateManagedMacro)
	end)
	MakeDragBox(0, "Set Focus", "Sets your current target as your focus and marks it.", "focus", function()
		PickupSlot("setFocusName", DEFAULTS.setFocusName, UpdateSetFocusMacro)
	end)
	MakeDragBox(78, "Tab Kick", "Interrupts the nearest casting enemy, then returns to your target.", "autotab", function()
		PickupSlot("autoTabName", DEFAULTS.autoTabName, UpdateAutoTabMacro)
	end)
	RefreshDragIcons()

	local p = DB.point or DEFAULTS.point
	frame:ClearAllPoints()
	frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	frame:Hide()
	return frame
end

function SMK.ShowUI(fromEvent)
	if EnsureDB() == nil then return end
	if not GDB.enabled then return end
	if InCombatLockdown() then
		-- Only tell the user when THEY asked (a trigger like a mid-key ready check stays silent).
		if not fromEvent then print(PREFIX .. "in combat, not opening (this is an out-of-combat tool).") end
		return
	end
	CreateUI()
	UpdateSelection()
	frame.readyCB:Refresh()
	frame.smartCB:Refresh()
	frame.announceCB:Refresh()
	frame.msgBox:SetText(DB.message or DEFAULTS.message)
	RefreshDragIcons()
	SyncMacros()
	frame:Show()
	frame:Raise()
end

--------------------------------------------------------------------------------
-- Macro editor
--------------------------------------------------------------------------------

local editorSlot = "kick"  -- which macro the editor edits: "kick" or "focus"

local function MacroNoteText()
	return "{interrupt} fills in your interrupt (now: " ..
		(GetMyInterruptName() or "none for this spec") .. "); {marker} fills in your marker."
end

function SMK.ShowMacroEditor()
	if EnsureDB() == nil then return end
	if macroFrame then
		macroFrame.note:SetText(MacroNoteText())
		macroFrame:Show()
		macroFrame:Raise()
		macroFrame.ReloadFields()
		return
	end

	macroFrame = CreateFrame("Frame", "ArcUI_SetMyKickMacroFrame", UIParent, "BackdropTemplate")
	macroFrame:SetSize(420, 416)
	macroFrame:SetFrameStrata("DIALOG")
	macroFrame:SetToplevel(true)
	macroFrame:SetClampedToScreen(true)
	macroFrame:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = false, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	macroFrame:SetBackdropColor(0.04, 0.04, 0.04, 0.9)
	macroFrame:SetMovable(true)
	macroFrame:EnableMouse(true)
	macroFrame:RegisterForDrag("LeftButton")
	macroFrame:SetScript("OnDragStart", macroFrame.StartMoving)
	macroFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local pt, _, rp, x, y = self:GetPoint()
		DB.macroPoint = { pt, rp, x, y }
	end)
	tinsert(UISpecialFrames, "ArcUI_SetMyKickMacroFrame")

	local close = CreateFrame("Button", nil, macroFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Edit Macro")

	local nameLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	nameLabel:SetPoint("TOPLEFT", 24, -80)
	nameLabel:SetText("Macro name:")

	local nameBox = CreateFrame("EditBox", nil, macroFrame, "InputBoxTemplate")
	nameBox:SetSize(130, 20)
	nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
	macroFrame.nameBox = nameBox

	local note = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 24, -106)
	note:SetPoint("TOPRIGHT", -24, -106)
	note:SetJustifyH("LEFT")
	macroFrame.note = note
	note:SetText(MacroNoteText())

	local bodyLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	bodyLabel:SetPoint("TOPLEFT", 24, -132)
	bodyLabel:SetText("Macro body ({interrupt} and {marker} are filled in for you):")

	local scroll = CreateFrame("ScrollFrame", "ArcUI_SetMyKickMacroScroll", macroFrame, "InputScrollFrameTemplate")
	scroll:SetSize(372, 96)
	scroll:SetPoint("TOPLEFT", 24, -152)
	scroll.EditBox:SetMultiLine(true)
	scroll.EditBox:SetMaxLetters(255)
	scroll.EditBox:SetWidth(360)
	scroll.EditBox:SetFontObject(ChatFontNormal)
	if scroll.CharCount then scroll.CharCount:Hide() end
	macroFrame.scroll = scroll

	local border = CreateFrame("Frame", nil, macroFrame, "BackdropTemplate")
	border:SetPoint("TOPLEFT", scroll, "TOPLEFT", -6, 6)
	border:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 22, -6)
	border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })

	-- Which macro this editor is editing.
	local function CurrentName()
		local cfg = SLOT_CFG[editorSlot]
		local n = DB[cfg.nameKey]
		return (n and n ~= "") and n or cfg.defName
	end
	local function CurrentTemplate()
		local cfg = SLOT_CFG[editorSlot]
		return DB[cfg.tmplKey] or cfg.defBody
	end
	local markerBtn  -- created below; only shown for the kick/focus slots (Tab Kick has no marker)
	local function ReloadFields()
		nameBox:SetText(CurrentName())
		nameBox:SetCursorPosition(0)
		scroll.EditBox:SetText(CurrentTemplate())
		scroll.EditBox:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
		if markerBtn then markerBtn:SetShown(editorSlot == "kick" or editorSlot == "focus") end
	end
	local function ApplySlot(name, template)
		local cfg = SLOT_CFG[editorSlot]
		DB[cfg.nameKey] = name
		DB[cfg.tmplKey] = template
		if editorSlot == "kick" then
			DB.macroEnabled = true
			UpdateManagedMacro()
		elseif editorSlot == "focus" then
			UpdateSetFocusMacro(true)
		else
			UpdateAutoTabMacro(true)
		end
	end
	macroFrame.ReloadFields = ReloadFields

	-- Slot selector: pick which macro to edit.
	local editLabel = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	editLabel:SetPoint("TOPLEFT", 24, -50)
	editLabel:SetText("Editing:")

	local slotDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	slotDrop:SetSize(160, 22)
	slotDrop:SetPoint("LEFT", editLabel, "RIGHT", 10, 0)
	local function SlotIsSelected(sk) return editorSlot == sk end
	local function SlotSetSelected(sk) editorSlot = sk; C_Timer.After(0, ReloadFields) end
	slotDrop:SetupMenu(function(dropdown, root)
		for _, key in ipairs(SLOT_ORDER) do
			root:CreateRadio(SLOT_CFG[key].label, SlotIsSelected, SlotSetSelected, key)
		end
	end)

	-- Pick an existing macro to load it. Built as a plain ScrollFrame + buttons rather
	-- than a WowStyle1Dropdown: the dropdown's ScrollBox compares a secret content
	-- extent inside instances and throws under our taint. A plain ScrollFrame (same
	-- tech as the body editor) is taint-safe, so the editor stays usable in dungeons.
	local pickBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	pickBtn:SetSize(150, 22)
	pickBtn:SetPoint("LEFT", nameBox, "RIGHT", 12, 0)
	pickBtn:SetText("Import Existing")

	local pickPanel = CreateFrame("Frame", nil, pickBtn, "BackdropTemplate")
	pickPanel:SetSize(196, 210)
	pickPanel:SetPoint("TOPLEFT", pickBtn, "BOTTOMLEFT", 0, -2)
	pickPanel:SetFrameStrata("FULLSCREEN_DIALOG")
	pickPanel:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	pickPanel:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
	pickPanel:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	pickPanel:Hide()

	local pickScroll = CreateFrame("ScrollFrame", nil, pickPanel)
	pickScroll:SetPoint("TOPLEFT", 6, -6)
	pickScroll:SetPoint("BOTTOMRIGHT", -6, 6)
	pickScroll:EnableMouseWheel(true)
	local pickChild = CreateFrame("Frame", nil, pickScroll)
	pickChild:SetSize(180, 10)
	pickScroll:SetScrollChild(pickChild)
	pickScroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = math.max(0, pickChild:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * 36)))
	end)

	local pickRows = {}
	local function PopulatePicker()
		for _, r in ipairs(pickRows) do r:Hide() end
		local count = 0
		local function AddRow(actualIndex)
			local mname = GetMacroInfo(actualIndex)
			if not mname or mname == "" then return end
			count = count + 1
			local r = pickRows[count]
			if not r then
				r = CreateFrame("Button", nil, pickChild)
				r:SetHeight(18)
				r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				r.text:SetPoint("LEFT", 6, 0)
				r.text:SetPoint("RIGHT", -4, 0)
				r.text:SetJustifyH("LEFT")
				pickRows[count] = r
			end
			r:SetPoint("TOPLEFT", pickChild, "TOPLEFT", 0, -(count - 1) * 18)
			r:SetPoint("TOPRIGHT", pickChild, "TOPRIGHT", 0, -(count - 1) * 18)
			r.text:SetText(mname)
			r._idx = actualIndex
			r:SetScript("OnClick", function(self)
				-- Import the BODY only into the slot you're editing. The addon keeps
				-- managing its own macro (the name above is unchanged) -- picking copies
				-- commands in as a starting point, it does NOT repoint to this macro.
				local _, _, body = GetMacroInfo(self._idx)
				scroll.EditBox:SetText(body or "")
				scroll.EditBox:SetCursorPosition(0)
				scroll:SetVerticalScroll(0)
				pickPanel:Hide()
			end)
			r:Show()
		end
		local numAccount, numChar = GetNumMacros()
		for i = 1, numAccount do AddRow(i) end
		for i = 1, numChar do AddRow(MAX_ACCOUNT_MACROS + i) end
		pickChild:SetHeight(math.max(1, count * 18))
		pickScroll:SetVerticalScroll(0)
	end

	pickBtn:SetScript("OnClick", function()
		if pickPanel:IsShown() then
			pickPanel:Hide()
		else
			PopulatePicker()
			pickPanel:Show()
			pickPanel:Raise()
		end
	end)

	local info = macroFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	info:SetPoint("TOPLEFT", 24, -256)
	info:SetPoint("TOPRIGHT", -24, -256)
	info:SetJustifyH("LEFT")
	info:SetText("Import Existing copies a macro's commands in as a starting point; Save writes them to the macro named above (the addon's own). For Focus + Kick and Set Focus, click \"Add / Sync Marker Line\" first to add the marker line.")

	local saveBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	saveBtn:SetSize(170, 24)
	saveBtn:SetPoint("BOTTOMLEFT", 30, 18)
	saveBtn:SetText("Save & Update Macro")
	saveBtn:SetScript("OnClick", function()
		local nm = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if nm == "" then nm = CurrentName() end
		ApplySlot(nm, scroll.EditBox:GetText())
		nameBox:SetText(nm)
	end)

	-- Add or sync the {marker} marker line in the body (kick/focus slots only; shown via ReloadFields).
	markerBtn = CreateFrame("Button", nil, macroFrame, "UIPanelButtonTemplate")
	markerBtn:SetSize(210, 22)
	markerBtn:SetPoint("BOTTOM", 0, 50)
	markerBtn:SetText("Add / Sync Marker Line")
	markerBtn:SetScript("OnClick", function()
		scroll.EditBox:SetText(ManageMarkerInBody(scroll.EditBox:GetText()))
		scroll.EditBox:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
	end)

	local templateDrop = CreateFrame("DropdownButton", nil, macroFrame, "WowStyle1DropdownTemplate")
	templateDrop:SetSize(190, 24)
	templateDrop:SetPoint("BOTTOMRIGHT", -30, 18)
	templateDrop:SetDefaultText("Choose a template...")
	templateDrop:SetupMenu(function(dropdown, root)
		root:SetScrollMode(20 * 16)
		for _, t in ipairs(TEMPLATES[editorSlot] or {}) do
			local body = t.body
			root:CreateButton(t.name, function()
				scroll.EditBox:SetText(body)
				local nm = (nameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
				if nm == "" then nm = CurrentName() end
				ApplySlot(nm, body)
				nameBox:SetText(nm)
			end)
		end
	end)

	local p = DB.macroPoint or DEFAULTS.macroPoint
	macroFrame:ClearAllPoints()
	macroFrame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	macroFrame:Show()
	macroFrame:Raise()
	ReloadFields()
end

--------------------------------------------------------------------------------
-- Runtime activation (only while enabled and not dormant)
--------------------------------------------------------------------------------

local function ActivateRuntime()
	if not eventFrame then
		eventFrame = CreateFrame("Frame")
		eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
			if not (DB and GDB.enabled) then return end
			if event == "READY_CHECK" then
				-- In a Mythic+ dungeon: pop the picker (out of combat) and, before
					-- the key locks chat, auto-announce. Announce(true) self-skips once
					-- the key is active, so it never causes a blocked-action error.
					if ShouldTriggerHere() then
						if DB.showOnReadyCheck then
								if DB.smartOpen then ArmSmartOpen() else SMK.ShowUI(true) end
							end
						if DB.announceOnReadyCheck then Announce(true) end
					end
			elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
				or event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER"
				or event == "CHAT_MSG_INSTANCE_CHAT" or event == "CHAT_MSG_INSTANCE_CHAT_LEADER" then
				-- Smart Open watch: arg1 = text, arg2 = sender. Skip your own echo (cached name), then
				-- if another player calls your marker, open so you can change your focus.
				if GetTime() > smartOpenExpire then
					DisarmSmartOpen()
				elseif myName and arg2 and not issecretvalue(arg2)
						and arg2:match("^[^-]+") ~= myName and MessageCallsMyMarker(arg1) then
					DisarmSmartOpen()
					SMK.ShowUI(true)
				end
			elseif event == "PLAYER_REGEN_ENABLED" then
				SyncMacros()
			elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
				if arg1 == "player" then SyncMacros() end
				elseif event == "PLAYER_ENTERING_WORLD" then
					RememberMyName()  -- cache our name out in the world (it is secret inside M+)
			end
		end)
	end
	eventFrame:RegisterEvent("READY_CHECK")
	eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
end

local function DeactivateRuntime()
	if eventFrame then eventFrame:UnregisterAllEvents() end
	if frame then frame:Hide() end
end

--------------------------------------------------------------------------------
-- Options tab (right of Cooldown Reminder)
--------------------------------------------------------------------------------

function ns.GetSetMyKickOptionsTable()
	EnsureDB()

	if IsStandaloneLoaded() then
		return {
			type = "group",
			name = "Kick Assist",
			args = {
				notice = {
					type = "description", order = 1, fontSize = "medium",
					name = "|cffffd200Kick Assist|r is running as a standalone addon, so the built-in version is turned off to avoid duplicates.",
				},
				open = {
					type = "execute", order = 2, width = 1.5,
					name = "Open Kick Assist",
					func = function()
						if KickAssist_Show then
							KickAssist_Show()
						elseif SlashCmdList["KICKASSIST"] then
							SlashCmdList["KICKASSIST"]("")
						end
					end,
				},
				macro = {
					type = "execute", order = 3, width = 1.5,
					name = "Edit Kick Macro",
					func = function()
						if KickAssist_ShowMacroEditor then KickAssist_ShowMacroEditor() end
					end,
				},
				tip = {
					type = "description", order = 4, fontSize = "small",
					name = "To use the version built into ArcUI instead, disable the standalone \"Kick Assist\" addon and reload.",
				},
			},
		}
	end

	local args = {
		enabled = {
			type = "toggle", order = 0, width = "full",
			name = "Enable Kick Assist",
			desc = "Turn on the built-in interrupt-marker tool: pick a kick marker, announce it, and keep your macro synced.",
			get = function() return GDB.enabled end,
			set = function(_, v)
				GDB.enabled = v
				if v then ActivateRuntime() else DeactivateRuntime() end
			end,
		},
	}

	if not GDB.enabled then
		args.off = {
			type = "description", order = 1, fontSize = "medium",
			name = "Enable the toggle above to use Kick Assist: claim an interrupt raid marker, call it out to your group, and keep your kick macro pointed at it.",
		}
		return { type = "group", name = "Kick Assist", args = args }
	end

	local markerValues = {}
	for i = 0, 8 do markerValues[i] = MARKER_NAMES[i] end

	args.open = {
		type = "execute", order = 1, width = 1.3,
		name = "Open Kick Assist",
		func = function() SMK.ShowUI() end,
	}
	args.editMacro = {
		type = "execute", order = 2, width = 1.3,
		name = "Edit Kick Macro",
		func = function() SMK.ShowMacroEditor() end,
	}
	args.hdr = { type = "header", order = 3, name = "" }
	args.marker = {
		type = "select", order = 4, width = 1.3,
		name = "Kick marker",
		values = markerValues,
		sorting = { 1, 2, 3, 4, 5, 6, 7, 8, 0 },
		get = function() return DB.marker end,
		set = function(_, v)
			DB.marker = v
			UpdateSelection()
			UpdateManagedMacro()
		end,
	}
	args.readyCheck = {
		type = "toggle", order = 5, width = 1.6,
		name = "Show on ready check",
		get = function() return DB.showOnReadyCheck end,
		set = function(_, v) DB.showOnReadyCheck = v end,
	}
	args.announceReady = {
		type = "toggle", order = 5.5, width = 1.6,
		name = "Announce on ready check",
		desc = "Post your kick to group chat on a ready check (before a Mythic+ key starts). Auto-skips once the key locks chat.",
		get = function() return DB.announceOnReadyCheck end,
		set = function(_, v) DB.announceOnReadyCheck = v end,
	}
	args.contexts = {
		type = "multiselect", order = 5.7, width = "full",
		name = "Open / announce on ready check in",
		desc = "Which instance types trigger the ready-check popup and announce. Default: Mythic dungeons only.",
		values = CONTEXT_VALUES,
		get = function(_, key)
			local v = DB.contexts and DB.contexts[key]
			if v == nil then v = CONTEXT_DEFAULTS[key] end
			return v and true or false
		end,
		set = function(_, key, val)
			DB.contexts = DB.contexts or {}
			DB.contexts[key] = val and true or false
		end,
	}
	args.smartOpen = {
		type = "toggle", order = 6, width = 1.6,
		name = "Smart open (only on a marker clash)",
		desc = "After a ready check, instead of opening right away, watch party chat briefly and open only if someone else calls your marker, so you can change your focus. Needs \"Show on ready check\" on.",
		get = function() return DB.smartOpen end,
		set = function(_, v) DB.smartOpen = v end,
	}
	args.message = {
		type = "input", order = 7, width = 2.0,
		name = "Announce message (%MARKER% = your marker icon)",
		get = function() return DB.message end,
		set = function(_, v) DB.message = v end,
	}
	args.descx = {
		type = "description", order = 8, fontSize = "small",
		name = "Marking uses the game's built-in /tm command from your macro. This only keeps the marker in the macro synced to your pick.",
	}
	args.standaloneHdr = { type = "header", order = 9, name = "" }
	args.standaloneNote = {
		type = "description", order = 10, fontSize = "small",
		name = "|cff66ccffAlso available as a standalone addon.|r If you (or a friend) want just this interrupt helper without ArcUI, grab \"Kick Assist\" on CurseForge or Wago.",
	}

	return { type = "group", name = "Kick Assist", args = args }
end

--------------------------------------------------------------------------------
-- Init (called from ArcUI_Options login timer)
--------------------------------------------------------------------------------

function SMK.Init()
	EnsureDB()
	if IsStandaloneLoaded() then return end -- standalone owns it; stay dormant

	if not slashRegistered then
		slashRegistered = true
		SLASH_ARCKICKASSIST1 = "/ka"
		SLASH_ARCKICKASSIST2 = "/arckick"
		SlashCmdList["ARCKICKASSIST"] = function(msg)
			if not (DB and GDB.enabled) then
				print(PREFIX .. "the built-in version is off. Enable it in ArcUI options, Kick Assist tab.")
				return
			end
			msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
			if msg == "hide" then
				if frame then frame:Hide() end
			elseif msg == "macro" then
				SMK.ShowMacroEditor()
			else
				SMK.ShowUI()
			end
		end
	end

	if GDB.enabled then ActivateRuntime() end
end
