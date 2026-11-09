-- The player's own XP and what is known about everyone else's.

local _, ns = ...

local Tracker = {}
ns.Tracker = Tracker

local Protocol = ns.Protocol
local Plain = ns.Plain

local STATUS_MIN_GAP = 10
local LEVEL_DEBOUNCE = 1
local HEARTBEAT_SECONDS = 30
local ONLINE_WINDOW = 90        -- last resort, for someone the game's own lists don't cover
local SILENT_SECONDS = 150      -- online but quiet this long: they've stopped running Dingus
local ALERT_MAX_GAP = 900       -- a level gained while unseen isn't news
local QUEST_SCAN_DELAY = 1      -- QUEST_LOG_UPDATE comes in bursts
local SELF_KEY = ":self"        -- a colon can't be in a character name

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

function Tracker.FormatNumber(number)
    local text = tostring(math.floor(number or 0))
    local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

--- 35500 -> "35.5k"
function Tracker.FormatShort(number)
    number = math.floor(number or 0)
    if number < 1000 then return tostring(number) end
    if number < 1000000 then return ("%.1fk"):format(number / 1000) end
    return ("%.1fm"):format(number / 1000000)
end

function Tracker.FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds < 60 then return "<1m" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours >= 100 then return "100h+" end
    if hours > 0 then return ("%dh %dm"):format(hours, minutes) end
    return ("%dm"):format(minutes)
end

function Tracker.FormatAgo(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 86400) .. "d"
end

-- XP rate over a rolling window. All times are seconds from any steady clock.
local Rate = { WINDOW = 900, MIN_SPAN = 60 }
Tracker.Rate = Rate

local function PruneSamples(samples, now)
    while samples[1] and now - samples[1].at > Rate.WINDOW do table.remove(samples, 1) end
end

function Rate.New()
    return { samples = {} }
end

--- Records an observed XP state. A gap longer than the window restarts the
--- count, so XP earned while we weren't watching doesn't look like a spike.
function Rate.Add(rate, now, level, xp, xpMax)
    local gained = 0
    local fresh = rate.lastAt and now - rate.lastAt <= Rate.WINDOW
    if fresh then
        if level == rate.level then
            gained = math.max(0, xp - rate.xp)
        elseif level == rate.level + 1 then
            gained = math.max(0, (rate.xpMax or 0) - rate.xp) + xp
        elseif level > rate.level then
            gained = xp
        end
    else
        rate.samples = {}
    end
    PruneSamples(rate.samples, now)
    table.insert(rate.samples, { at = now, gained = gained })
    rate.lastAt, rate.level, rate.xp, rate.xpMax = now, level, xp, xpMax
end

--- XP per hour, or nil without recent gains.
function Rate.Get(rate, now)
    local samples = rate.samples
    PruneSamples(samples, now)
    local first = samples[1]
    if not first then return nil end
    local total = 0
    for i = 2, #samples do total = total + samples[i].gained end
    if total <= 0 then return nil end
    return total / math.max(now - first.at, Rate.MIN_SPAN) * 3600
end

--- Seconds to the next level at this rate, or nil.
function Rate.TimeToLevel(perHour, xp, xpMax)
    if not perHour or perHour <= 0 or not xpMax or xpMax <= 0 then return nil end
    return math.max(0, xpMax - xp) / perHour * 3600
end

-- Newest status wins: a friend in the guild arrives by two routes.
function Tracker.AcceptStatus(runtime, seq)
    if runtime.lastSeq and seq <= runtime.lastSeq then return false end
    runtime.lastSeq = seq
    return true
end

--- Pinned first, then online, then by the chosen order, with name breaking ties.
function Tracker.SortEntries(entries, sortBy, pinned)
    table.sort(entries, function(a, b)
        local pinA, pinB = pinned[a.peer.key] and 1 or 0, pinned[b.peer.key] and 1 or 0
        if pinA ~= pinB then return pinA > pinB end
        if a.online ~= b.online then return a.online end
        local pa, pb = a.peer, b.peer
        local fractionA = (pa.xpMax or 0) > 0 and pa.xp / pa.xpMax or 0
        local fractionB = (pb.xpMax or 0) > 0 and pb.xp / pb.xpMax or 0
        if sortBy == "level" then
            local totalA, totalB = (pa.level or 0) + fractionA, (pb.level or 0) + fractionB
            if totalA ~= totalB then return totalA > totalB end
        elseif sortBy == "progress" then
            if fractionA ~= fractionB then return fractionA > fractionB end
        elseif sortBy == "recent" then
            if (pa.seen or 0) ~= (pb.seen or 0) then return (pa.seen or 0) > (pb.seen or 0) end
        end
        return (pa.name or "") < (pb.name or "")
    end)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local runtimes = {} -- key -> { rate, lastSeq }
local peers = {}    -- key -> what they last sent. Never saved: it lasts the session.
Tracker.peers = peers
local me
local seq = 0
local statusTimerPending = false
local lastStatusSent
local questScanPending = false
local demo

local function Runtime(key)
    local runtime = runtimes[key]
    if not runtime then
        runtime = { rate = Rate.New() }
        runtimes[key] = runtime
    end
    return runtime
end
Tracker.Runtime = Runtime

local function NextSeq()
    -- Based on the clock, so a /reload can't reuse numbers others already saw.
    seq = math.max(seq + 1, time())
    return seq
end

--- A unit's two-part name, or just the first part when that's all the game gives.
function Tracker.ReadFullName(unit)
    local given, second = UnitFullName(unit)
    given = Plain(given) or Plain(UnitName(unit))
    if not given then return nil end
    second = Plain(second)
    -- On Forever the surname sits in UnitFullName's realm slot (LevelRacer/Utils.lua).
    if not given:find(" ", 1, true) and second
        and second ~= Plain(GetRealmName()) and second ~= Plain(GetNormalizedRealmName()) then
        return given .. " " .. second
    end
    return given
end

function Tracker:MyName()
    return Tracker.ReadFullName("player")
end

local function ReadZone()
    return Plain(GetRealZoneText()) or Plain(GetZoneText())
end

local function Snapshot()
    local name = Tracker:MyName() or "?"
    local _, class = UnitClass("player")
    me = me or { questXP = 0 }
    me.key = SELF_KEY
    me.name = name
    me.class = class or "WARRIOR"
    me.level = UnitLevel("player") or 1
    me.xp = UnitXP("player") or 0
    me.xpMax = UnitXPMax("player") or 0
    me.rested = GetXPExhaustion() or 0
    me.zone = ReadZone()
    me.seen = time()
    Rate.Add(Runtime(SELF_KEY).rate, GetTime(), me.level, me.xp, me.xpMax)
end

function Tracker:EncodeOwnStatus()
    if not me then Snapshot() end
    return Protocol.EncodeStatus({
        seq = NextSeq(), level = me.level, xp = me.xp, xpMax = me.xpMax, rested = me.rested,
        class = me.class, name = me.name, zone = ns.settings.shareZone and me.zone or nil,
        questXP = me.questXP,
    })
end

local function SendStatusNow()
    lastStatusSent = GetTime()
    ns.Comm:BroadcastStatus(Tracker:EncodeOwnStatus())
end

--- Sends our status to everyone, at most once per STATUS_MIN_GAP. Anything asked
--- for sooner waits, so a run of kills folds into one message with the latest XP.
function Tracker:SendStatus()
    if statusTimerPending then return end
    local wait = lastStatusSent and lastStatusSent + STATUS_MIN_GAP - GetTime() or 0
    if wait <= 0 then
        SendStatusNow()
        return
    end
    statusTimerPending = true
    C_Timer.After(wait, function()
        statusTimerPending = false
        SendStatusNow()
    end)
end

local function OnOwnChange()
    Snapshot()
    Tracker:SendStatus()
    ns.UI:Refresh()
end

--- XP from every quest in the log that's ready to turn in.
local function ReadCompletedQuestXP()
    local log = C_QuestLog
    if not (GetQuestLogRewardXP and log and log.GetNumQuestLogEntries
        and log.GetQuestIDForLogIndex and log.IsComplete) then
        return 0
    end
    local total = 0
    for i = 1, log.GetNumQuestLogEntries() do
        local questID = log.GetQuestIDForLogIndex(i)
        if questID and questID > 0 and log.IsComplete(questID) then
            total = total + (GetQuestLogRewardXP(questID) or 0)
        end
    end
    return total
end

local function OnQuestLogUpdate()
    if questScanPending then return end
    questScanPending = true
    C_Timer.After(QUEST_SCAN_DELAY, function()
        questScanPending = false
        local total = ReadCompletedQuestXP()
        if total ~= me.questXP then
            me.questXP = total
            Tracker:SendStatus()
            ns.UI:Refresh()
        end
    end)
end

function Tracker:Start()
    Snapshot()
    me.questXP = ReadCompletedQuestXP()
    ns.On("PLAYER_XP_UPDATE", OnOwnChange)
    ns.On("UPDATE_EXHAUSTION", OnOwnChange)
    ns.On("ZONE_CHANGED_NEW_AREA", OnOwnChange)
    ns.On("PLAYER_ENTERING_WORLD", OnOwnChange)
    ns.On("QUEST_LOG_UPDATE", OnQuestLogUpdate)
    ns.On("PLAYER_LEVEL_UP", function()
        -- UnitLevel is out of date while this event fires.
        C_Timer.After(LEVEL_DEBOUNCE, function()
            Snapshot()
            Tracker:SendStatus()
            ns.UI:Refresh()
        end)
    end)
    C_Timer.NewTicker(HEARTBEAT_SECONDS, function() Tracker:SendStatus() end)
end

--------------------------------------------------------------------------------
-- Other players
--------------------------------------------------------------------------------

function Tracker:OnStatus(msg, route, account)
    local key = Protocol.NameKey(msg.name)
    local runtime = Runtime(key)
    if not Tracker.AcceptStatus(runtime, msg.seq) then return end

    local peer = peers[key]
    if not peer then
        peer = { key = key }
        peers[key] = peer
    end
    local previousLevel, previousSeen = peer.level, peer.seen

    peer.name, peer.class = msg.name, msg.class
    peer.level, peer.xp, peer.xpMax, peer.rested = msg.level, msg.xp, msg.xpMax, msg.rested
    peer.zone, peer.questXP = msg.zone, msg.questXP
    peer.seen = time()
    if account then peer.account = account end
    if route.kind == "guild" then peer.guild = ns.Roster:GuildName() end

    Rate.Add(runtime.rate, GetTime(), msg.level, msg.xp, msg.xpMax)

    if previousLevel and msg.level > previousLevel and previousSeen
        and peer.seen - previousSeen <= ALERT_MAX_GAP then
        ns.UI:ShowLevelUp(peer)
    end
    ns.UI:Refresh()
end

--- true or false, or nil for someone the game lists as online who has stopped
--- sending, as after turning Dingus off. What they last sent is out of date.
local function IsOnline(peer)
    local quiet = time() - (peer.seen or 0)
    local state = ns.Roster:OnlineState(peer)
    if state == nil then return quiet < ONLINE_WINDOW end
    if state and quiet > SILENT_SECONDS then return nil end
    return state
end

--- What the panel shows: { self = entry, party, friends, guild, friendsOnline, guildOnline }.
--- Characters on one Battle.net account share a row, led by the one in play.
function Tracker:BuildList()
    if demo then return demo:BuildList() end
    local s = ns.settings
    local byAccount = {}
    local groups = { party = {}, friends = {}, guild = {} }

    for key, peer in pairs(peers) do
        local online = IsOnline(peer)
        if online == nil then
            -- Forgotten, so a later status starts fresh rather than as a level-up.
            peers[key], runtimes[key] = nil, nil
        end
        local group = online ~= nil and ns.Roster:GroupOf(peer)
        if group and not s.hidden[key] then
            local entry = { peer = peer, online = online, runtime = Runtime(key), group = group }
            if peer.account then
                local lead = byAccount[peer.account]
                if not lead then
                    byAccount[peer.account] = entry
                elseif (entry.online and not lead.online)
                    or (entry.online == lead.online and (peer.seen or 0) > (lead.peer.seen or 0)) then
                    entry.alts = lead.alts or {}
                    table.insert(entry.alts, lead.peer)
                    lead.alts = nil
                    byAccount[peer.account] = entry
                else
                    lead.alts = lead.alts or {}
                    table.insert(lead.alts, peer)
                end
            else
                table.insert(groups[group], entry)
            end
        end
    end
    for _, entry in pairs(byAccount) do
        table.insert(groups[entry.group], entry)
    end

    local function Visible(entry)
        if not s.showOffline and not entry.online then return false end
        local maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion() or GetMaxPlayerLevel()
        if not s.showMaxLevel and entry.peer.level >= maxLevel then return false end
        return true
    end
    local function Filter(list)
        local out, online = {}, 0
        for _, entry in ipairs(list) do
            if entry.online then online = online + 1 end
            if Visible(entry) then out[#out + 1] = entry end
        end
        Tracker.SortEntries(out, s.sortBy, s.pinned)
        return out, online
    end
    local shownParty = Filter(groups.party)
    local shownFriends, friendsOnline = Filter(groups.friends)
    local shownGuild, guildOnline = Filter(groups.guild)
    return {
        self = { peer = me, online = true, runtime = Runtime(SELF_KEY), isSelf = true },
        party = shownParty,
        friends = shownFriends,
        guild = s.showGuild and shownGuild or {},
        friendsOnline = friendsOnline,
        guildOnline = guildOnline,
    }
end

--------------------------------------------------------------------------------
-- /dingus demo: sample players for trying the panel alone. Never saved.
--------------------------------------------------------------------------------

local DEMO_TICK = 3

local function DemoPeer(key, name, class, level, xp, xpMax, rested, questXP, zone, seenAgo)
    return {
        key = key, name = name, class = class, level = level, xp = xp, xpMax = xpMax, rested = rested,
        questXP = questXP, zone = zone, seen = time() - seenAgo,
    }
end

function Tracker:IsDemo()
    return demo ~= nil
end

function Tracker:ToggleDemo()
    if demo then
        demo.ticker:Cancel()
        demo = nil
        ns.UI:Refresh()
        return false
    end

    local mira = DemoPeer("demo:mira", "Mira Vale", "MAGE", 41, 56400, 112800, 13536, 9024, "Tanaris", 12)
    local list = {
        party = {
            { peer = DemoPeer("demo:rhea", "Rhea Stone", "ROGUE", 40, 71500, 104000, 10400, 12480, "Tanaris", 5), online = true },
            { peer = DemoPeer("demo:bram", "Bram Holt", "PALADIN", 40, 31200, 104000, 0, 8320, "Tanaris", 8), online = true },
        },
        friends = {
            { peer = mira, online = true },
            { peer = DemoPeer("demo:tomas", "Tomas Reed", "DRUID", 39, 35340, 93000, 27900, 0, nil, 40), online = true },
            { peer = DemoPeer("demo:ana", "Ana Smith", "PRIEST", 36, 11250, 75000, 0, 3000, "Desolace", 10800), online = false },
        },
        guild = {
            { peer = DemoPeer("demo:joss", "Joss Harrow", "HUNTER", 44, 12060, 134000, 0, 16080, nil, 120), online = true },
            { peer = DemoPeer("demo:wren", "Wren Alder", "WARLOCK", 38, 55040, 86000, 5160, 4300, nil, 60), online = true },
        },
    }
    for _, group in ipairs({ list.party, list.friends, list.guild }) do
        for _, entry in ipairs(group) do
            entry.runtime = Runtime(entry.peer.key)
            Rate.Add(entry.runtime.rate, GetTime() - 600, entry.peer.level, 0, entry.peer.xpMax)
            Rate.Add(entry.runtime.rate, GetTime(), entry.peer.level, entry.peer.xp, entry.peer.xpMax)
        end
    end

    demo = {}
    function demo:BuildList()
        local s = ns.settings
        local function Shown(entries)
            local out, online = {}, 0
            for _, entry in ipairs(entries) do
                if entry.online then online = online + 1 end
                if entry.online or s.showOffline then out[#out + 1] = entry end
            end
            Tracker.SortEntries(out, s.sortBy, s.pinned)
            return out, online
        end
        local party = Shown(list.party)
        local friends, friendsOnline = Shown(list.friends)
        local guild, guildOnline = Shown(list.guild)
        return {
            self = { peer = me, online = true, runtime = Runtime(SELF_KEY), isSelf = true },
            party = s.showParty and party or {},
            friends = friends,
            guild = s.showGuild and guild or {},
            friendsOnline = friendsOnline, guildOnline = guildOnline,
        }
    end
    -- Walks Mira through XP and a level so the bar and toast can be seen.
    demo.ticker = C_Timer.NewTicker(DEMO_TICK, function()
        local runtime = Runtime(mira.key)
        local gain = math.floor(mira.xpMax * 0.12)
        mira.xp = mira.xp + gain
        if mira.xp >= mira.xpMax then
            mira.xp = mira.xp - mira.xpMax
            mira.level = mira.level + 1
            ns.UI:ShowLevelUp(mira)
        end
        Rate.Add(runtime.rate, GetTime(), mira.level, mira.xp, mira.xpMax)
        ns.UI:Refresh()
    end)
    ns.UI:Refresh()
    return true
end
