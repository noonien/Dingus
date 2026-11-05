-- Runs the whole addon against a fake WoW API: login, routing, rendering,
-- tooltips, settings and demo mode. It catches runtime errors and routing
-- mistakes, but says nothing about how the game itself behaves.
-- From the addon folder: nix-shell -p lua5_1 --run 'lua tests/smoke.lua'

local clock = 1000
local timers, tickers, frames, fontStrings = {}, {}, {}, {}
local sent = {}
local tooltip = {}
local printed = {}
local cursorOver = true
local group = { home = false, instance = false, raid = false, members = {} }

local function noop() end

local function NewWidget(kind)
    local widget = { kind = kind, scripts = {}, shown = true, points = {} }
    local methods = {
        SetPoint = function(self, ...) table.insert(self.points, { ... }) end,
        SetGradient = function(self, _, bottom, top) self.gradientBottom, self.gradientTop = bottom, top end,
        ClearAllPoints = function(self) self.points = {} end,
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
        GetScript = function(self, name) return self.scripts[name] end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetShown = function(self, value) self.shown = value and true or false end,
        IsShown = function(self) return self.shown end,
        IsMouseOver = function() return cursorOver end,
        SetText = function(self, text) self.text = text end,
        GetText = function(self) return self.text end,
        SetWidth = function(self, value)
            assert(type(value) == "number" and value == value, "SetWidth needs a real number")
            self.width = value
        end,
        SetHeight = function(self, value)
            assert(type(value) == "number" and value == value, "SetHeight needs a real number")
            self.height = value
        end,
        GetStringWidth = function() return 120 end,
        GetHeight = function(self) return self.height end,
        GetTop = function() return 700 end,
        GetBottom = function() return 400 end,
        GetLeft = function() return 36 end,
        GetCenter = function() return 170 end,
        GetAlpha = function(self) return self.alpha or 1 end,
        SetAlpha = function(self, value) self.alpha = value end,
        GetVerticalScrollRange = function() return 100 end,
        GetVerticalScroll = function() return 0 end,
        GetThumbTexture = function(self)
            self.thumb = self.thumb or NewWidget("Texture")
            return self.thumb
        end,
        CreateTexture = function() return NewWidget("Texture") end,
        CreateFontString = function(self)
            local text = NewWidget("FontString")
            text.owner = self
            table.insert(fontStrings, text)
            return text
        end,
        CreateLine = function() return NewWidget("Line") end,
        CreateAnimationGroup = function() return NewWidget("AnimationGroup") end,
        CreateAnimation = function() return NewWidget("Animation") end,
        Play = function(self)
            if self.scripts.OnFinished then self.scripts.OnFinished(self) end
        end,
    }
    return setmetatable(widget, {
        __index = function(_, key)
            -- Only API-style names (capitalised) act as no-op methods, so fields read as nil.
            return methods[key] or (key:find("^%u") and noop or nil)
        end,
    })
end

CreateFrame = function(kind, name)
    local frame = NewWidget(kind)
    frame.frameName = name
    table.insert(frames, frame)
    return frame
end
UIParent = NewWidget("Frame")
UIParent.GetWidth = function() return 1920 end
DEFAULT_CHAT_FRAME = NewWidget("Frame")
GameTooltip = NewWidget("GameTooltip")
GameTooltip.AddLine = function(_, text) table.insert(tooltip, text) end
GameTooltip.AddDoubleLine = function(_, a, b) table.insert(tooltip, a .. "=" .. b) end
GameTooltip.SetOwner = function() tooltip = {} end

GetTime = function() return clock end
time = function() return 1800000000 + clock end
print = function(text) table.insert(printed, text) end
unpack = unpack or table.unpack

C_Timer = {
    After = function(delay, fn) table.insert(timers, { at = clock + delay, fn = fn }) end,
    NewTicker = function(every, fn)
        local t = { every = every, fn = fn, at = clock + every }
        function t:Cancel() self.cancelled = true end
        table.insert(tickers, t)
        return t
    end,
}

-- Steps time in small slices, so a timer started by a timer fires when it should.
local STEP = 0.05
local REGULAR_UPDATE_SECONDS = 30

local function Advance(seconds)
    for _ = 1, math.ceil(seconds / STEP) do
        clock = clock + STEP
        for i = #timers, 1, -1 do
            if timers[i].at <= clock then
                local timer = table.remove(timers, i)
                timer.fn()
            end
        end
        for _, t in ipairs(tickers) do
            if not t.cancelled and t.at <= clock then
                t.at = t.at + t.every
                t.fn()
            end
        end
    end
end

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return 0 end,
    InChatMessagingLockdown = function() return false end,
    SendAddonMessage = function(_, text, channel, target)
        table.insert(sent, { channel = channel, target = target, text = text })
        return 0
    end,
}
C_EventUtils = { IsEventValid = function() return true end }
BNET_CLIENT_WOW = "WoW"
WOW_PROJECT_ID = 99
BNGetNumFriends = function() return 1 end
C_BattleNet = {
    SendGameData = function(id, _, text)
        table.insert(sent, { channel = "BN", target = id, text = text })
    end,
    GetFriendAccountInfo = function()
        return { battleTag = "Mira#1", accountName = "Mira" }
    end,
    GetFriendNumGameAccounts = function() return 1 end,
    GetFriendGameAccountInfo = function()
        return { gameAccountID = 55, isOnline = true, clientProgram = "WoW", wowProjectID = 99, characterName = "Mira Vale" }
    end,
}
C_FriendList = {
    GetNumFriends = function() return 1 end,
    GetFriendInfoByIndex = function() return { name = "Tomas Reed", connected = true } end,
    ShowFriends = noop,
}
C_GuildInfo = { GuildRoster = noop }
IsInGuild = function() return true end
GetGuildInfo = function() return "Test Guild" end
GetNumGuildMembers = function() return 1 end
GetGuildRosterInfo = function() return "Joss Harrow", nil, nil, 44, nil, nil, nil, nil, true end
UnitFullName = function(unit)
    if unit == "player" then return "Ana", "Smith" end
    local member = group.members[unit]
    if member.secret then error("secret") end
    return member.first, member.last
end
UnitName = function(unit)
    if unit == "player" then return "Ana" end
    return group.members[unit].first
end
UnitClass = function() return "Priest", "PRIEST" end
UnitLevel = function() return 38 end
UnitXP = function() return 500 end
UnitXPMax = function() return 1000 end
GetXPExhaustion = function() return 100 end
LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE = 1, 2
IsInRaid = function() return group.raid end
IsInGroup = function(category)
    if category == LE_PARTY_CATEGORY_INSTANCE then return group.instance end
    if category == LE_PARTY_CATEGORY_HOME then return group.home end
    return group.home or group.instance or group.raid
end
UnitExists = function(unit) return group.members[unit] ~= nil end
UnitIsConnected = function(unit) return group.members[unit].connected ~= false end
local questLog = { { id = 1, complete = false, xp = 300 }, { id = 2, complete = false, xp = 999 } }
C_QuestLog = {
    GetNumQuestLogEntries = function() return #questLog end,
    GetQuestIDForLogIndex = function(i) return questLog[i].id end,
    IsComplete = function(id) return questLog[id].complete end,
}
GetQuestLogRewardXP = function(id) return questLog[id].xp end
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
GetRealmName = function() return "Ruleset" end
GetNormalizedRealmName = function() return "Ruleset" end
GetRealZoneText = function() return "Tanaris" end
GetZoneText = function() return "Tanaris" end
GetBuildInfo = function() return "1.60", "1", "", 16001 end
GetMaxLevelForPlayerExpansion = function() return 60 end
InCombatLockdown = function() return false end
IsInInstance = function() return false end
MouseIsOver = function() return false end
PlaySound = noop
SOUNDKIT = { TELL_MESSAGE = 1 }
STANDARD_TEXT_FONT, UNIT_NAME_FONT, DAMAGE_TEXT_FONT = "a", "b", "c"
RAID_CLASS_COLORS = { MAGE = { r = 0.2, g = 0.7, b = 0.9 }, PRIEST = { r = 1, g = 1, b = 1 } }
CLASS_ICON_TCOORDS = { MAGE = { 0.25, 0.5, 0, 0.25 } }
LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage", PRIEST = "Priest" }
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
local chatFilter
ChatFrame_AddMessageEventFilter = function(_, fn) chatFilter = fn end
local whispered
ChatFrame_SendBNetTell = function(name) whispered = name end
SlashCmdList = {}
local panel
Settings = {
    RegisterCanvasLayoutCategory = function(frame)
        panel = frame
        return { GetID = function() return 1 end }
    end,
    RegisterAddOnCategory = noop,
    OpenToCategory = noop,
}

local ns = {}
for _, file in ipairs({ "Core", "Comm", "Roster", "Tracker", "UI", "Options" }) do
    assert(loadfile(file .. ".lua"))("Dingus", ns)
end
local eventFrame = frames[1]
local function Fire(event, ...) eventFrame.scripts.OnEvent(eventFrame, event, ...) end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write("FAIL ", name, "\n  ", tostring(err), "\n")
    end
end

local function Sent(channel, kindPattern)
    local n = 0
    for _, message in ipairs(sent) do
        if (not channel or message.channel == channel) and message.text:find(kindPattern) then n = n + 1 end
    end
    return n
end

local cursor = { x = 100, y = 100 }
GetCursorPosition = function() return cursor.x, cursor.y end

--- A click: press and release with the cursor where it is.
local function Press(button, mouse)
    button.scripts.OnMouseDown(button, mouse)
    button.scripts.OnMouseUp(button, mouse)
end

--- A press that moves the cursor, setting off a drag, then releases.
local function Drag(button, distance)
    button.scripts.OnMouseDown(button, "LeftButton")
    cursor.x = cursor.x + distance
    button.scripts.OnDragStart(button)
    button.scripts.OnDragStop(button)
    button.scripts.OnMouseUp(button, "LeftButton")
    cursor.x = 100
end

local function Rows()
    local out = {}
    for _, frame in ipairs(frames) do
        if frame.kind == "Button" and frame.entry and frame.shown then out[#out + 1] = frame end
    end
    return out
end

local function RowNames()
    local names = {}
    for _, row in ipairs(Rows()) do names[row.name:GetText()] = row end
    return names
end

local SEP_S = "^1~S~"

-- These rows are off by default; most tests need them on.
local function ShowEverything()
    local s = ns.settings
    s.showSelf, s.showOffline, s.showMaxLevel, s.showGuild = true, true, true, true
end

test("loads and logs in", function()
    DingusAddonDB = nil
    Fire("ADDON_LOADED", "Dingus")
    assert(DingusAddonDB.settings.sharing == true)
    ShowEverything()
    Fire("PLAYER_LOGIN")
    Advance(2)
end)

test("login greets each friend and the guild once, by the right route", function()
    Advance(10)
    assert(Sent("BN", "^1~H$") == 1, "battle.net hello")
    assert(Sent("WHISPER", "^1~H$") == 1, "whisper hello")
    assert(Sent("GUILD", "^1~H$") == 1, "guild hello")
    Fire("FRIENDLIST_UPDATE")
    Advance(10)
    assert(Sent(nil, "^1~H$") == 3, "not greeted twice")
end)

test("the player's own bar shows the two-part name's row", function()
    Advance(1)
    assert(RowNames()["You"], "own row")
    assert(ns.Tracker:MyName() == "Ana Smith", "my name: " .. tostring(ns.Tracker:MyName()))
end)

test("xp isn't sent to friends who haven't shown they run the addon", function()
    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("BN", SEP_S) == 0, "battle.net")
    assert(Sent("WHISPER", SEP_S) == 0, "whisper")
    assert(Sent("GUILD", SEP_S) == 1, "guild broadcast")
end)

test("a hello from a friend gets a reply by the same route", function()
    Advance(11) -- lets a held-back status go out first
    sent = {}
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~H", "WHISPER", 55)
    Advance(1)
    assert(Sent("BN", SEP_S) == 1)
end)

test("a Battle.net status adds a row and a working tooltip", function()
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~S~100~41~50000~100000~1000~MAGE~Mira Vale~Desolace", "WHISPER", 55)
    Advance(1)
    local row = RowNames()["Mira Vale"]
    assert(row, "row")
    assert(row.percent:GetText() == "50.0k/100.0k (50%)", "text: " .. tostring(row.percent:GetText()))
    assert(row.name:GetText() == "Mira Vale" and row.level:GetText() == 41, "name and level")
    row.scripts.OnEnter(row)
    local text = table.concat(tooltip, "\n")
    assert(text:find("Level 41 Mage", 1, true), text)
    assert(text:find("Zone=Desolace", 1, true), text)
    assert(text:find("3 |4level:levels; ahead of you", 1, true), text)
    row.scripts.OnLeave(row)
end)

test("that friend now gets xp updates", function()
    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("BN", SEP_S) == 1)
end)

test("the zone is only sent when shared", function()
    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("BN", "Tanaris") == 0, "off by default")
    ns.settings.shareZone = true
    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("BN", "Tanaris") == 1, "on")
    ns.settings.shareZone = false
end)

--- For tests counting exact sends or requests, which the status and guild roster
--- tickers would throw off.
local function WithoutRegularUpdates(fn)
    local paused = {}
    for _, ticker in ipairs(tickers) do
        if ticker.every == REGULAR_UPDATE_SECONDS then
            ticker.at = math.huge
            paused[#paused + 1] = ticker
        end
    end
    Advance(11) -- lets a held-back status go out first
    fn()
    for _, ticker in ipairs(paused) do ticker.at = clock + REGULAR_UPDATE_SECONDS end
end

test("completed quests are read from the log, sent, and rescanned when they change", function()
    WithoutRegularUpdates(function()
    sent = {}
    questLog[1].complete = true
    Fire("QUEST_LOG_UPDATE")
    Fire("QUEST_LOG_UPDATE")
    Advance(10)
    assert(Sent("BN", "~300$") == 1, "only the finished quest counts")
    assert(Sent("GUILD", "~300$") == 1, "guild too")

    sent = {}
    Fire("QUEST_LOG_UPDATE")
    Advance(10)
    assert(#sent == 0, "no message when nothing changed")
    questLog[1].complete = false
    Fire("QUEST_LOG_UPDATE")
    Advance(10)
    assert(Sent("BN", "~0$") == 1, "turned in, so back to none")
    end)
end)

test("the bar shows current xp, then finished quests, then rested", function()
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~S~110~41~50000~100000~10000~MAGE~Mira Vale~~20000", "WHISPER", 55)
    Advance(1)
    local row = RowNames()["Mira Vale"]
    local whole = row.barWidth
    local function near(a, b) return math.abs(a - b) < 0.001 end
    assert(near(row.fill.width, whole * 0.5), "fill")
    assert(near(row.quest.points[1][4], whole * 0.5) and near(row.quest.width, whole * 0.2), "quest")
    assert(near(row.rest.points[1][4], whole * 0.7) and near(row.rest.width, whole * 0.1), "rested")
    assert(row.fill.shown and row.quest.shown and row.rest.shown)
    assert(row.fill.gradientTop.a == 1, "current xp is solid")
    local questTop, restTop = row.quest.gradientTop, row.rest.gradientTop
    assert(questTop.a > 0.5 and questTop.a < 1 and restTop.a == questTop.a, "quest and rested visible but see-through")
    assert(questTop.r > 0.4 and restTop.b > 0.4, "brighter than the fill, or they vanish")
    assert(row.fill.gradientTop.b <= 0.3, "colours are muted")

    row.scripts.OnEnter(row)
    local text = table.concat(tooltip, "\n")
    assert(text:find("Completed quests=20,000 (20%)", 1, true), text)
    assert(text:find("Rested=10,000 (10%)", 1, true), text)
    assert(not text:find("Recent quests", 1, true), "no quest list")
    row.scripts.OnLeave(row)
    assert(row.extra:GetText() == "", "no quest text on the row")

    -- Together they can't run past the end of the bar.
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~S~111~41~50000~100000~10000~MAGE~Mira Vale~~90000", "WHISPER", 55)
    Advance(1)
    assert(near(row.quest.width, whole * 0.5), "quest stops at the end")
    assert(not row.rest.shown, "no room left for rested")

    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~S~112~41~50000~100000~0~MAGE~Mira Vale~~0", "WHISPER", 55)
    Advance(1)
    assert(not row.quest.shown and not row.rest.shown, "empty segments hide")
end)

test("a guildmate lands in the guild group, and senders can't impersonate", function()
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~200~44~1~100~0~MAGE~Joss Harrow", "GUILD", "Joss Harrow")
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~201~60~1~100~0~MAGE~Mira Vale", "GUILD", "Joss Harrow")
    Advance(1)
    assert(RowNames()["Joss Harrow"], "guild row")
    assert(ns.Roster:GroupOf(DingusAddonDB.peers["joss harrow"]) == "guild")
    assert(DingusAddonDB.peers["mira vale"].level == 41, "impersonation refused")
end)

test("whispers from non-friends and our own echoes are ignored", function()
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~300~10~1~100~0~MAGE~Stranger Danger", "WHISPER", "Stranger Danger")
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~301~10~1~100~0~MAGE~Ana Smith", "GUILD", "Ana Smith")
    Fire("CHAT_MSG_ADDON", "OtherAddon", "1~S~302~10~1~100~0~MAGE~Joss Harrow", "GUILD", "Joss Harrow")
    Advance(1)
    assert(not DingusAddonDB.peers["stranger danger"])
    assert(not DingusAddonDB.peers["ana smith"])
    assert(DingusAddonDB.peers["joss harrow"].level == 44, "other prefix ignored")
end)

test("a character friend's whisper route works", function()
    sent = {}
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~H", "WHISPER", "Tomas Reed")
    Advance(2)
    assert(Sent("WHISPER", SEP_S) == 1)
    assert(sent[1].target == "Tomas Reed")
end)

test("stopping sharing with one friend stops their updates, not the guild's", function()
    ns.settings.excluded["mira vale"] = true
    ns.settings.excluded["account:Mira#1"] = true
    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("BN", SEP_S) == 0, "friend excluded")
    assert(Sent("GUILD", SEP_S) == 1, "guild continues")
    ns.settings.excluded = {}
end)

test("share switches stop what they name", function()
    sent = {}
    ns.settings.shareGuild = false
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("GUILD", SEP_S) == 0 and Sent("BN", SEP_S) == 1, "guild off")
    ns.settings.shareGuild = true

    sent = {}
    ns.settings.shareFriends = false
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("GUILD", SEP_S) == 1 and Sent("BN", SEP_S) == 0, "friends off")
    ns.settings.shareFriends = true

    sent = {}
    ns.settings.sharing = false
    Fire("PLAYER_XP_UPDATE")
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~H", "WHISPER", 55)
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~H", "GUILD", "Joss Harrow")
    Advance(10)
    assert(#sent == 0, "master switch: " .. #sent)
    ns.settings.sharing = true
end)

test("a backlog of status updates coalesces, and lockdown holds sends", function()
    local locked = true
    C_ChatInfo.InChatMessagingLockdown = function() return locked end
    sent = {}
    for _ = 1, 3 do
        ns.Tracker:SendStatus()
        Advance(1)
    end
    assert(#sent == 0, "held in lockdown")
    locked = false
    Advance(5)
    assert(Sent("BN", SEP_S) == 1, "one battle.net status: " .. Sent("BN", SEP_S))
    assert(Sent("GUILD", SEP_S) == 1, "one guild status")
end)

test("a throttled send is retried, not lost", function()
    WithoutRegularUpdates(function()
    local original = C_ChatInfo.SendAddonMessage
    local refusals = 2
    C_ChatInfo.SendAddonMessage = function(...)
        if refusals > 0 then
            refusals = refusals - 1
            return 3
        end
        return original(...)
    end
    sent = {}
    ns.Comm:BroadcastStatus("1~S~999~38~1~2~0~PRIEST~Ana Smith~~0")
    Advance(30)
    C_ChatInfo.SendAddonMessage = original
    assert(Sent("GUILD", "^1~S~999") == 1, "delivered after retries")
    end)
end)

test("a friend who logs off is dimmed and shows how long ago", function()
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~S~1000~42~1~100000~0~MAGE~Mira Vale", "WHISPER", 55)
    Advance(1)
    assert(RowNames()["Mira Vale"].level:GetText() == 42)
    C_BattleNet.GetFriendNumGameAccounts = function() return 0 end
    Fire("BN_FRIEND_INFO_CHANGED")
    Advance(20)
    local row = RowNames()["Mira Vale"]
    assert(row and not row.entry.online, "offline")
    assert(row.extra:GetText():find("%d[smhd]$"), "ago text: " .. tostring(row.extra:GetText()))
    row.scripts.OnEnter(row)
    assert(table.concat(tooltip, "\n"):find("Not playing", 1, true))
    C_BattleNet.GetFriendNumGameAccounts = function() return 1 end
    Fire("BN_FRIEND_INFO_CHANGED")
    Advance(5)
end)

test("the saved record survives into a new session's shape", function()
    assert(DingusAddonDB.peers["mira vale"].key == "mira vale")
    assert(DingusAddonDB.peers["mira vale"].account == "Mira#1")
end)

test("left-click whispers by Battle.net account", function()
    local row = RowNames()["Mira Vale"]
    Press(row, "LeftButton")
    assert(whispered == "Mira", "whispered: " .. tostring(whispered))
    local own = RowNames()["You"]
    whispered = nil
    Press(own, "LeftButton")
    assert(whispered == nil, "own row does nothing")
end)

test("the right-click menu builds and its actions work", function()
    local actions = {}
    local root = {
        CreateTitle = noop,
        CreateButton = function(_, label, fn) actions[label] = fn end,
    }
    MenuUtil = { CreateContextMenu = function(_, build) build(nil, root) end }
    C_PartyInfo = { InviteUnit = function(name) actions.invited = name end }
    local row = RowNames()["Mira Vale"]
    Press(row, "RightButton")
    actions["Invite"]()
    assert(actions.invited == "Mira Vale")
    actions["Pin to top"]()
    assert(ns.settings.pinned["mira vale"])
    actions["Stop sharing my XP with them"]()
    assert(ns.settings.excluded["mira vale"] and ns.settings.excluded["account:Mira#1"])
    Press(row, "RightButton")
    actions["Share my XP with them"]()
    assert(not next(ns.settings.excluded), "cleared")
    actions["Hide"]()
    Advance(1)
    assert(not RowNames()["Mira Vale"], "hidden")
    ns.settings.hidden = {}
    Advance(1)
    MenuUtil, C_PartyInfo = nil, nil
end)

test("each section folds on its own, shows its count, and drags the panel", function()
    local buttons = {}
    for _, frame in ipairs(frames) do
        if frame.kind == "Button" and frame.scripts.OnDragStart and not frame.track then
            buttons[#buttons + 1] = frame
        end
    end
    local friends, guild = buttons[2], buttons[3]
    local function Click(button, mouse)
        Press(button, mouse or "LeftButton")
        Advance(1)
    end
    ns.UI:ApplySettings()
    assert(RowNames()["Mira Vale"] and RowNames()["Joss Harrow"], "both open")

    Click(friends)
    assert(ns.settings.collapsedSections.friends, "saved")
    assert(not RowNames()["Mira Vale"], "friends folded")
    assert(RowNames()["Joss Harrow"], "guild still open")
    assert(RowNames()["You"], "own bar stays")

    Click(guild)
    assert(not RowNames()["Joss Harrow"], "guild folded")
    local counts = {}
    for _, text in ipairs(fontStrings) do
        if tostring(text.text):find("^%d+ online$") then counts[#counts + 1] = text.text end
    end
    assert(counts[1] == "1 online" and counts[2] == "1 online", "counts stay while folded")

    Click(friends)
    Click(guild)
    assert(RowNames()["Mira Vale"] and RowNames()["Joss Harrow"], "both open again")

    -- A real drag moves the panel and doesn't fold anything.
    ns.settings.anchor = nil
    Drag(friends, 50)
    Advance(1)
    assert(not ns.settings.collapsedSections.friends, "a drag isn't a click")
    assert(ns.settings.anchor and ns.settings.anchor.left == 36, "position saved")

    -- The old bug: a drag with no click after it swallowed the next real click.
    friends.scripts.OnMouseDown(friends, "LeftButton")
    cursor.x = 150
    friends.scripts.OnDragStart(friends)
    friends.scripts.OnDragStop(friends)
    cursor.x = 100
    Click(friends)
    assert(ns.settings.collapsedSections.friends, "the click after a drag still folds")
    Click(friends)

    -- A shaky click that the game reports as a drag is still a click, and doesn't move the panel.
    ns.settings.anchor = nil
    Drag(friends, 3)
    Advance(1)
    assert(ns.settings.collapsedSections.friends, "a slight movement still folds")
    assert(ns.settings.anchor == nil or ns.settings.anchor.left == 36, "no new position from a shaky click")
    Click(friends)

    -- Letting go somewhere else cancels it.
    cursorOver = false
    Click(friends)
    cursorOver = true
    assert(not ns.settings.collapsedSections.friends, "released off the header")

    Click(friends, "RightButton")
    assert(not ns.settings.collapsedSections.friends, "right-click opens settings instead")

    -- Growing upward, folding still holds the top edge (the fake panel's is 700).
    local main
    for _, frame in ipairs(frames) do
        if frame.frameName == "DingusFrame" then main = frame end
    end
    ns.settings.growUp = true
    ns.UI:ApplySettings()
    local tallest = main.height
    Click(friends)
    assert(main.height < tallest, "shorter when folded")
    assert(main.points[1][1] == "BOTTOMLEFT" and main.points[1][5] == 700 - main.height, "top held folding")
    Click(friends)
    assert(main.points[1][1] == "BOTTOMLEFT" and main.points[1][5] == 700 - tallest, "top held unfolding")
    ns.settings.growUp = false
    ns.UI:ApplySettings()
    Click(friends)
    assert(main.points[1][1] == "TOPLEFT" and main.points[1][5] == 700, "growing down holds it anyway")
    Click(friends)

    ns.settings.locked = true
    ns.settings.anchor = nil
    Drag(friends, 50)
    assert(ns.settings.anchor == nil, "locked: no move")
    assert(not ns.settings.collapsedSections.friends, "locked: a long drag isn't a click either")
    Click(friends)
    assert(ns.settings.collapsedSections.friends, "locked: clicks work")
    ns.settings.locked = false
    Click(friends)
end)

test("party members with the addon get their own section, and nobody else does", function()
    sent = {}
    group.home = true
    group.members.party1 = { first = "Rhea", last = "Stone" }
    group.members.party2 = { first = "Joss", last = "Harrow" }
    Fire("GROUP_ROSTER_UPDATE")
    Advance(3)
    assert(Sent("PARTY", "^1~H$") == 1, "hello on joining")

    -- Rhea runs the addon and isn't a friend; the unnamed third member doesn't run it.
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~600~40~1~100~0~MAGE~Rhea Stone", "PARTY", "Rhea Stone")
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~601~44~1~100~0~MAGE~Joss Harrow", "PARTY", "Joss Harrow")
    Advance(1)
    local list = ns.Tracker:BuildList()
    local function has(entries, key)
        for _, entry in ipairs(entries) do
            if entry.peer.key == key then return true end
        end
    end
    assert(has(list.party, "rhea stone"), "stranger in the party")
    assert(has(list.party, "joss harrow") and not has(list.guild, "joss harrow"), "listed once, under party")
    assert(RowNames()["Rhea Stone"], "row")
    assert(RowNames()["Mira Vale"].points[1][5] > RowNames()["Rhea Stone"].points[1][5], "friends above party")
    for _, text in ipairs(fontStrings) do
        if text.owner.scripts.OnDragStart and not text.owner.track and tostring(text.text):find("PARTY", 1, true) then
            for _, other in ipairs(fontStrings) do
                if other.owner == text.owner then
                    assert(not tostring(other.text):find("online", 1, true), "party has no online count")
                end
            end
        end
    end

    sent = {}
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~H", "PARTY", "Rhea Stone")
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~H", "PARTY", "Joss Harrow")
    Advance(6)
    assert(Sent("PARTY", SEP_S) == 1, "many hellos, one reply")

    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("PARTY", SEP_S) == 1, "xp updates reach the party")
    sent = {}
    ns.settings.shareParty = false
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("PARTY", SEP_S) == 0, "share switch")
    ns.settings.shareParty = true

    -- Only someone new sets off a fresh hello.
    sent = {}
    Fire("GROUP_ROSTER_UPDATE")
    Advance(3)
    assert(Sent("PARTY", "^1~H$") == 0, "no new member")
    group.members.party3 = { first = "Bram", last = "Holt" }
    Fire("GROUP_ROSTER_UPDATE")
    Advance(3)
    assert(Sent("PARTY", "^1~H$") == 1, "new member")

    -- Unreadable names in a dungeon keep the list as it was.
    group.members.party1.secret = true
    Fire("GROUP_ROSTER_UPDATE")
    Advance(3)
    assert(ns.Roster:GroupOf(DingusAddonDB.peers["rhea stone"]) == "party", "kept while unreadable")
    group.members.party1.secret = nil

    group.members.party1.connected = false
    Fire("UNIT_CONNECTION")
    Advance(3)
    assert(ns.Roster:OnlineState(DingusAddonDB.peers["rhea stone"]) == false, "disconnected")

    -- A Dungeon Finder group talks on another channel.
    group.home, group.instance = false, true
    sent = {}
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("INSTANCE_CHAT", SEP_S) == 1, "instance channel")
    assert(Sent("PARTY", SEP_S) == 0, "not party")
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~602~41~1~100~0~MAGE~Rhea Stone", "INSTANCE_CHAT", "Rhea Stone")
    assert(DingusAddonDB.peers["rhea stone"].level == 41, "heard there too")

    -- Raids stay out of it.
    group.instance, group.raid = false, true
    sent = {}
    Fire("GROUP_ROSTER_UPDATE")
    Fire("PLAYER_XP_UPDATE")
    Advance(10)
    assert(Sent("PARTY", ".") == 0 and Sent("RAID", ".") == 0, "raid")

    -- After leaving, a stranger drops off and a guildmate goes back to the guild.
    group.raid, group.members = false, {}
    Fire("GROUP_ROSTER_UPDATE")
    Advance(3)
    assert(not RowNames()["Rhea Stone"], "stranger gone")
    assert(ns.Roster:GroupOf(DingusAddonDB.peers["joss harrow"]) == "guild", "guildmate back")
end)

test("sections with nobody in them don't show, and rows can drag the panel", function()
    local main, buttons = nil, {}
    for _, frame in ipairs(frames) do
        if frame.frameName == "DingusFrame" then main = frame end
        if frame.kind == "Button" and frame.scripts.OnDragStart and not frame.track then
            buttons[#buttons + 1] = frame
        end
    end
    local party, friends, guild = buttons[1], buttons[2], buttons[3]
    local s = ns.settings
    ns.UI:ApplySettings()
    assert(not party.shown, "party hidden with nobody in it")
    assert(friends.shown and guild.shown, "the others stay")

    s.showGuild = false
    ns.UI:ApplySettings()
    assert(not guild.shown, "guild off")

    s.hidden["mira vale"] = true
    ns.UI:ApplySettings()
    assert(not friends.shown, "friends hidden when its only player is")
    assert(main.shown, "own bar still there")
    s.showSelf = false
    ns.UI:ApplySettings()
    assert(not main.shown, "nothing to show, so no panel")
    s.hidden = {}
    ShowEverything()
    ns.UI:ApplySettings()
    assert(main.shown and friends.shown and guild.shown, "all back")

    local row = RowNames()["Mira Vale"]
    whispered = nil
    Drag(row, 50)
    assert(whispered == nil, "a drag doesn't whisper")
    Press(row, "LeftButton")
    assert(whispered == "Mira", "the next click does")
    Drag(RowNames()["You"], 50)
    assert(ns.settings.anchor, "the own bar drags too")
    ns.UI:ResetPosition()
end)

test("every bar text, colour, sort and visibility setting renders", function()
    local s = ns.settings
    local function Check(key, values)
        local before = s[key]
        for _, value in ipairs(values) do
            s[key] = value
            ns.UI:ApplySettings()
            Advance(1)
        end
        s[key] = before
        ns.UI:ApplySettings()
    end
    Check("barText", { "full", "percent", "level", "none" })
    Check("barColor", { "class", "sky", "mint", "violet", "rose" })
    Check("font", { "default", "names", "damage" })
    Check("sortBy", { "level", "progress", "name", "recent" })
    Check("growUp", { true, false })
    Check("shown", { false, true })
    Check("showSelf", { false, true })
    Check("showGuild", { false, true })
    Check("showParty", { false, true })
    Check("showOffline", { false, true })
    Check("showMaxLevel", { false, true })
    Check("hideInCombat", { true, false })
    Check("hideInInstance", { true, false })
    Check("hideWhenAlone", { true, false })
    Check("maxRows", { 1, 20 })
    Check("alertWho", { "friends", "pinned", "all" })
end)

test("growing upward holds the bottom edge, and switching doesn't move the panel", function()
    local main
    for _, frame in ipairs(frames) do
        if frame.frameName == "DingusFrame" then main = frame end
    end
    local s = ns.settings

    s.growUp = false
    ns.UI:ResetPosition()
    assert(main.points[1][1] == "TOPLEFT" and main.points[1][3] == "TOPLEFT" and main.points[1][5] == -220, "default, down")
    local height = main.height

    s.growUp = true
    ns.UI:ResetPosition()
    assert(main.points[1][1] == "BOTTOMLEFT" and main.points[1][3] == "BOTTOMLEFT" and main.points[1][5] == 220, "default, up")
    assert(main.height == height, "same size either way")

    -- The fake panel's edges are 700 and 400.
    ns.UI:ApplySettings()
    assert(main.points[1][1] == "BOTTOMLEFT" and main.points[1][5] == 400, "up: bottom edge held")
    s.growUp = false
    ns.UI:ApplySettings()
    assert(main.points[1][1] == "TOPLEFT" and main.points[1][5] == 700, "down: top edge held")
    ns.UI:ResetPosition()
end)

test("the row limit shows how many are left out", function()
    ns.settings.maxRows = 1
    ns.UI:ApplySettings()
    local found
    for _, text in ipairs(fontStrings) do
        if text.shown and tostring(text.text):find("^%+%d+ more$") then found = text.text end
    end
    assert(found == "+1 more", "more text: " .. tostring(found))
    ns.settings.maxRows = 20
    ns.UI:ApplySettings()
end)

test("a max-level player renders full, with no XP lines", function()
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~900~60~0~0~0~MAGE~Joss Harrow", "GUILD", "Joss Harrow")
    Advance(1)
    local row = RowNames()["Joss Harrow"]
    assert(row.percent:GetText() == "Max", tostring(row.percent:GetText()))
    row.scripts.OnEnter(row)
    assert(not table.concat(tooltip, "\n"):find("XP/hour", 1, true))
    row.scripts.OnLeave(row)
end)

test("the settings panel opens and its controls work", function()
    panel.scripts.OnShow(panel)
    local clicked = 0
    local sharing = ns.settings.sharing
    for _, frame in ipairs(frames) do
        if frame.kind == "Button" and not frame.track and frame.scripts.OnClick and not frame.scripts.OnDragStart then
            frame.scripts.OnClick(frame, "LeftButton")
            frame.scripts.OnClick(frame, "RightButton")
            clicked = clicked + 1
        end
        if frame.kind == "Slider" then
            frame.scripts.OnValueChanged(frame, 24)
        end
    end
    assert(clicked > 20, "controls: " .. clicked)
    ns.settings.sharing = sharing
    ns.db.settings = ns.InitDB({}).settings
    ns.settings = ns.db.settings
    ShowEverything()
    ns.UI:ApplySettings()
    Advance(1)
end)

test("by default only online friends below max level are listed and counted", function()
    local defaults = ns.InitDB({}).settings
    for _, key in ipairs({ "showOffline", "showMaxLevel", "showGuild", "alertToast" }) do
        assert(defaults[key] == false, key .. " should be off")
    end
    assert(defaults.opacity == 0, "no background")
    assert(defaults.shown == true and defaults.showSelf == true, "panel and own bar on")
    local main
    for _, frame in ipairs(frames) do
        if frame.frameName == "DingusFrame" then main = frame end
    end
    ShowEverything()
    ns.settings.shown = false
    ns.UI:ApplySettings()
    assert(not main.shown, "unticking hides the panel")
    ns.settings.shown = true
    ns.UI:ApplySettings()
    assert(main.shown, "ticking shows it again")
    assert(defaults.showParty == true and defaults.shareParty == true, "party on")
    local s = ns.settings
    s.showSelf, s.showOffline, s.showMaxLevel, s.showGuild = false, false, false, false
    ns.UI:ApplySettings()
    local names = RowNames()
    assert(not names["You"], "own bar")
    assert(not names["Joss Harrow"], "guildmate")
    assert(names["Mira Vale"], "online friend")
    local count
    for _, text in ipairs(fontStrings) do
        count = count or tostring(text.text):match("^%d+ online$")
    end
    assert(count == "1 online", "friends section: " .. tostring(count))
    ShowEverything()
    ns.UI:ApplySettings()
end)

test("status goes out at most once every 10 seconds, and every 30 when idle", function()
    WithoutRegularUpdates(function()
    sent = {}
    for _ = 1, 40 do
        Fire("PLAYER_XP_UPDATE")
        Advance(1)
    end
    local busy = Sent("GUILD", SEP_S)
    assert(busy >= 4 and busy <= 5, "constant xp, 40 seconds: " .. busy)

    Advance(21) -- one held-back status, then a full gap after it
    sent = {}
    Fire("PLAYER_LEVEL_UP")
    Advance(2)
    assert(Sent("GUILD", SEP_S) == 1, "a level-up goes out promptly after a quiet spell")
    Fire("PLAYER_LEVEL_UP")
    Advance(2)
    assert(Sent("GUILD", SEP_S) == 1, "a second one waits for the limit")
    Advance(9)
    assert(Sent("GUILD", SEP_S) == 2, "then goes out")
    end)

    Advance(11)
    sent = {}
    Advance(90)
    assert(Sent("GUILD", SEP_S) == 3, "idle, 90 seconds: " .. Sent("GUILD", SEP_S))
end)

test("a guildmate going offline is picked up from the game's presence event", function()
    WithoutRegularUpdates(function()
    local requests = 0
    local online = true
    C_GuildInfo.GuildRoster = function() requests = requests + 1 end
    GetGuildRosterInfo = function() return "Joss Harrow", nil, nil, 44, nil, nil, nil, nil, online end
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~S~5000~44~1~100000~0~ROGUE~Joss Harrow", "GUILD", "Joss Harrow")
    Advance(11)
    Fire("GUILD_ROSTER_UPDATE")
    Advance(2)
    local peer = DingusAddonDB.peers["joss harrow"]
    assert(ns.Roster:OnlineState(peer) == true, "online to start with")

    Advance(11)
    requests = 0
    online = false
    Fire("CLUB_MEMBER_PRESENCE_UPDATED", 1, 2, 0)
    assert(requests == 1, "asks straight away: " .. requests)
    Fire("CLUB_MEMBER_PRESENCE_UPDATED", 1, 3, 0)
    Fire("CLUB_MEMBER_PRESENCE_UPDATED", 1, 4, 0)
    assert(requests == 1, "the limit holds a burst back")
    Fire("GUILD_ROSTER_UPDATE")
    Advance(2)
    assert(ns.Roster:OnlineState(peer) == false, "offline without waiting for a timeout")
    Advance(10)
    assert(requests == 2, "the held-back request isn't lost: " .. requests)

    C_GuildInfo.GuildRoster = noop
    GetGuildRosterInfo = function() return "Joss Harrow", nil, nil, 44, nil, nil, nil, nil, true end
    Fire("GUILD_ROSTER_UPDATE")
    Advance(2)
    end)
end)

test("the message timeout is only a last resort", function()
    local peers = DingusAddonDB.peers
    peers["nola wren"] = { key = "nola wren", name = "Nola Wren", guild = "Test Guild", class = "MAGE",
        level = 10, xp = 1, xpMax = 100, seen = time() }
    local function Entry()
        for _, entry in ipairs(ns.Tracker:BuildList().guild) do
            if entry.peer.key == "nola wren" then return entry end
        end
    end
    assert(ns.Roster:OnlineState(peers["nola wren"]) == nil, "not on any list")
    assert(Entry().online, "recent message")
    Advance(91)
    assert(not Entry().online, "silent too long")
    peers["nola wren"] = nil
    ns.UI:ApplySettings()
end)

test("slash commands", function()
    local slash = SlashCmdList.DINGUS
    local opened = 0
    local openToCategory = Settings.OpenToCategory
    Settings.OpenToCategory = function() opened = opened + 1 end
    slash("")
    assert(opened == 1, "/dingus opens settings")
    assert(ns.settings.shown == true, "/dingus leaves the panel alone")
    slash("options")
    assert(opened == 2, "/dingus options still works")
    Settings.OpenToCategory = openToCategory
    slash("reset")
    assert(ns.settings.anchor == nil)
    slash("help")
    slash("diag")
    Advance(10)
end)

test("diag reports a reply", function()
    printed = {}
    SlashCmdList.DINGUS("diag")
    Advance(1)
    local nonce
    for _, message in ipairs(sent) do
        nonce = message.text:match("^1~D~(%d+)$") or nonce
    end
    assert(nonce, "ping sent")
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~E~" .. nonce, "WHISPER", 55)
    Advance(10)
    assert(table.concat(printed, "\n"):find("Battle.net reached Mira Vale", 1, true), table.concat(printed, "\n"))
end)

test("a ping gets answered, and malformed text is only counted", function()
    sent = {}
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "1~D~77", "WHISPER", 55)
    Advance(2)
    assert(Sent("BN", "^1~E~77$") == 1)
    local before = ns.Comm.stats.rejected
    Fire("BN_CHAT_MSG_ADDON", "DingusXP", "not a message", "WHISPER", 55)
    assert(ns.Comm.stats.rejected == before + 1)
end)

test("demo mode shows samples, levels one up, and leaves saved data alone", function()
    local peersBefore = {}
    for key in pairs(DingusAddonDB.peers) do peersBefore[key] = true end
    SlashCmdList.DINGUS("demo")
    Advance(1)
    assert(RowNames()["Tomas Reed"] and RowNames()["Ana Smith"] and RowNames()["Wren Alder"], "rows")
    assert(RowNames()["Rhea Stone"], "party row")
    Advance(30)
    local mira = RowNames()["Mira Vale"]
    assert(mira and mira.level:GetText() >= 42, "levelled up")
    SlashCmdList.DINGUS("demo")
    Advance(1)
    assert(not RowNames()["Wren Alder"], "demo off")
    for key in pairs(DingusAddonDB.peers) do assert(peersBefore[key], "demo saved " .. key) end
end)

test("the not-found message is hidden only just after an addon whisper", function()
    local text = "No player named 'Tomas Reed' is currently playing."
    Advance(5)
    Fire("CHAT_MSG_ADDON", "DingusXP", "1~H", "WHISPER", "Tomas Reed")
    Advance(0.6)
    assert(chatFilter(nil, nil, text) == true, "hidden")
    assert(chatFilter(nil, nil, "Something else") == false, "other text kept")
    assert(chatFilter(nil, nil, nil) == false, "unreadable text doesn't raise")
    Advance(5)
    assert(chatFilter(nil, nil, text) == false, "shown later")
end)

io.write(("%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
