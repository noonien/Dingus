-- Messages between Dingus clients.
--
-- Everything received is data from another client: it is parsed into checked
-- numbers and cleaned strings, and never run. Text fields lose "|" so a sender
-- can't inject links or textures into the panel.
--
-- Wire format, fields separated by "~", version first:
--   1~H                                                hello: send me your status
--   1~S~seq~level~xp~xpMax~rested~CLASS~name~zone~questXP    status; zone may be empty
--   1~D~nonce / 1~E~nonce                              /dingus diag ping and reply

local _, ns = ...

local Protocol = {}
ns.Protocol = Protocol

Protocol.VERSION = "1"
Protocol.PREFIX = "DingusXP"
Protocol.MAX_BYTES = 255

local SEP = "~"
local MAX_INT = 2147483647
local MAX_LEVEL = 255
local MAX_NAME = 48
local MAX_ZONE = 48

--- Removes control characters and the bytes with a meaning here, trims, and
--- cuts to maxBytes without splitting a UTF-8 character. nil when nothing is left.
function Protocol.CleanText(value, maxBytes)
    if type(value) ~= "string" then return nil end
    local text = value:gsub("[%c|~]", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #text > maxBytes then
        local cut = maxBytes
        while cut > 0 do
            local nextByte = text:byte(cut + 1)
            if not nextByte or nextByte < 0x80 or nextByte >= 0xC0 then break end
            cut = cut - 1
        end
        text = text:sub(1, cut)
    end
    if text == "" then return nil end
    return text
end

local function ToNumber(value, maximum)
    if type(value) ~= "string" or #value > 10 or not value:find("^%d+$") then return nil end
    local number = tonumber(value)
    if not number or number > maximum then return nil end
    return number
end

local function Split(text)
    local parts, start = {}, 1
    while #parts < 12 do
        local at = text:find(SEP, start, true)
        if not at then
            parts[#parts + 1] = text:sub(start)
            break
        end
        parts[#parts + 1] = text:sub(start, at - 1)
        start = at + 1
    end
    return parts
end

function Protocol.EncodeHello()
    return Protocol.VERSION .. SEP .. "H"
end

function Protocol.EncodeStatus(s)
    local text = table.concat({
        Protocol.VERSION, "S", s.seq, s.level, s.xp, s.xpMax, s.rested or 0,
        s.class, Protocol.CleanText(s.name, MAX_NAME) or "?",
    }, SEP)
    return text .. SEP .. (Protocol.CleanText(s.zone, MAX_ZONE) or "") .. SEP .. (s.questXP or 0)
end

function Protocol.EncodePing(nonce)
    return Protocol.VERSION .. SEP .. "D" .. SEP .. nonce
end

function Protocol.EncodePong(nonce)
    return Protocol.VERSION .. SEP .. "E" .. SEP .. nonce
end

--- A checked message table, or nil for anything malformed.
function Protocol.Decode(text)
    if type(text) ~= "string" or #text > Protocol.MAX_BYTES then return nil end
    local p = Split(text)
    if p[1] ~= Protocol.VERSION then return nil end
    local kind = p[2]

    if kind == "H" then
        return { kind = "H" }

    elseif kind == "S" then
        local seq = ToNumber(p[3], MAX_INT)
        local level = ToNumber(p[4], MAX_LEVEL)
        local xp = ToNumber(p[5], MAX_INT)
        local xpMax = ToNumber(p[6], MAX_INT)
        local rested = ToNumber(p[7], MAX_INT)
        local class = p[8]
        local name = Protocol.CleanText(p[9], MAX_NAME)
        if not (seq and level and xp and xpMax and rested and name) or level < 1 then return nil end
        if type(class) ~= "string" or #class > 20 or not class:find("^%u+$") then return nil end
        if xpMax > 0 and xp > xpMax then xp = xpMax end
        return {
            kind = "S", seq = seq, level = level, xp = xp, xpMax = xpMax, rested = rested,
            class = class, name = name, zone = Protocol.CleanText(p[10], MAX_ZONE),
            questXP = ToNumber(p[11], MAX_INT) or 0,
        }

    elseif kind == "D" or kind == "E" then
        local nonce = ToNumber(p[3], MAX_INT)
        if not nonce then return nil end
        return { kind = kind, nonce = nonce }
    end
    return nil
end

--- "Ana Smith" -> "ana smith". The key peers are stored under.
function Protocol.NameKey(name)
    if type(name) ~= "string" then return nil end
    local key = name:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if key == "" then return nil end
    return key
end

function Protocol.FirstToken(name)
    if type(name) ~= "string" then return nil end
    local first = name:match("^%s*([^%s%-]+)")
    return first and first:lower() or nil
end

--- Forever's names have two parts, but some APIs give only the first. Two full
--- names must match exactly; otherwise compare the first part.
function Protocol.SameName(a, b)
    local keyA, keyB = Protocol.NameKey(a), Protocol.NameKey(b)
    if not keyA or not keyB then return false end
    if keyA == keyB then return true end
    if keyA:find(" ", 1, true) and keyB:find(" ", 1, true) then return false end
    return Protocol.FirstToken(keyA) == Protocol.FirstToken(keyB)
end

--------------------------------------------------------------------------------
-- Sending and receiving
--------------------------------------------------------------------------------

local Comm = {}
ns.Comm = Comm

local BURST = 6
local REFILL_SECONDS = 1.2
local PUMP_SECONDS = 0.5
local MAX_QUEUED = 300
local MAX_TRIES = 10
local DIAG_WAIT = 6
local WHISPER_ERROR_WINDOW = 2

-- Send results the client calls a throttle (measured by Blackthornes_Equipment).
local THROTTLE_CODES = { [3] = true, [8] = true }

local queue, lowQueue, pending = {}, {}, {}
local tokens, lastRefill = BURST, nil
local ticker
local greeted, known = {}, {}
local greetedParty = {}
local replyPending = {}
local lastWhisperAt = 0
local diag

Comm.stats = { sent = 0, refused = 0, received = 0, rejected = 0, throttled = 0 }

function Comm.RouteId(route)
    if route.kind == "bn" then return "bn:" .. tostring(route.id) end
    if route.kind == "whisper" then return "w:" .. tostring(Protocol.NameKey(route.target)) end
    return route.kind
end

local KIND_LABELS = { bn = "Battle.net", whisper = "Whisper", guild = "Guild", party = "Party" }

--- INSTANCE_CHAT in a Dungeon Finder group, PARTY in your own, nil solo and in a raid.
function Comm.PartyChannel()
    if IsInRaid() then return nil end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInGroup(LE_PARTY_CATEGORY_HOME) then return "PARTY" end
    return nil
end

local function RawSend(route, text)
    local ok, result
    if route.kind == "bn" then
        local send = (C_BattleNet and C_BattleNet.SendGameData) or BNSendGameData
        if not send then return "failed" end
        ok, result = pcall(send, route.id, Protocol.PREFIX, text)
    elseif route.kind == "whisper" then
        lastWhisperAt = GetTime()
        ok, result = pcall(C_ChatInfo.SendAddonMessage, Protocol.PREFIX, text, "WHISPER", route.target)
    elseif route.kind == "party" then
        local channel = Comm.PartyChannel()
        if not channel then return "failed" end
        ok, result = pcall(C_ChatInfo.SendAddonMessage, Protocol.PREFIX, text, channel)
    else
        ok, result = pcall(C_ChatInfo.SendAddonMessage, Protocol.PREFIX, text, "GUILD")
    end
    if not ok then return "failed" end
    -- Older APIs return nothing; newer ones true/false or a result code.
    if result == nil or result == true or result == 0 then return "sent" end
    if result == false or THROTTLE_CODES[result] then return "throttled" end
    return "failed"
end

local function InLockdown()
    if not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) then return false end
    local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
    return ok and locked == true
end

local function Pump()
    local list = #queue > 0 and queue or lowQueue
    if #list == 0 then
        if ticker then ticker:Cancel() ticker = nil end
        return
    end
    if InLockdown() then return end

    local now = GetTime()
    if lastRefill then tokens = math.min(BURST, tokens + (now - lastRefill) / REFILL_SECONDS) end
    lastRefill = now

    while tokens >= 1 do
        list = #queue > 0 and queue or lowQueue
        local entry = list[1]
        if not entry then return end
        local outcome = RawSend(entry.route, entry.text)
        if outcome == "throttled" then
            -- Stays at the front: the client refuses a throttled send, it doesn't queue it.
            tokens = 0
            Comm.stats.throttled = Comm.stats.throttled + 1
            entry.tries = (entry.tries or 0) + 1
            if entry.tries > MAX_TRIES then
                table.remove(list, 1)
                if entry.key then pending[entry.key] = nil end
                Comm.stats.refused = Comm.stats.refused + 1
            end
            return
        end
        table.remove(list, 1)
        if entry.key then pending[entry.key] = nil end
        tokens = tokens - 1
        if outcome == "sent" then
            Comm.stats.sent = Comm.stats.sent + 1
        else
            Comm.stats.refused = Comm.stats.refused + 1
        end
    end
end

--- Queue a message. With a coalesceKey, a newer message replaces one still
--- waiting, so a backlog of status updates can't build up.
local function Enqueue(route, text, coalesceKey, low)
    if coalesceKey and pending[coalesceKey] then
        pending[coalesceKey].text = text
        return
    end
    local list = low and lowQueue or queue
    if #list >= MAX_QUEUED then
        Comm.stats.refused = Comm.stats.refused + 1
        return
    end
    local entry = { route = route, text = text, key = coalesceKey }
    list[#list + 1] = entry
    if coalesceKey then pending[coalesceKey] = entry end
    if not ticker then
        ticker = C_Timer.NewTicker(PUMP_SECONDS, Pump)
        Pump()
    end
end

--- Has the player stopped sharing with this route's person?
function Comm:IsExcluded(route)
    local excluded = ns.settings.excluded
    -- Guild and party messages reach everyone there, so one person can't be left out.
    if route.kind == "guild" or route.kind == "party" or not next(excluded) then return false end
    if route.account and excluded["account:" .. route.account] then return true end
    local name = route.name or route.target
    for key in pairs(excluded) do
        if Protocol.SameName(key, name) then return true end
    end
    return false
end

local function CanShare(route)
    local s = ns.settings
    if Comm:IsExcluded(route) then return false end
    if route.kind == "guild" then return s.shareGuild and IsInGuild() end
    if route.kind == "party" then
        return s.shareParty and Comm.PartyChannel() ~= nil and #ns.Roster:PartyMembers() > 0
    end
    return s.shareFriends
end

--- Tells online friends and the guild that we're here. Sent once per route, and
--- also with sharing off: a hello carries no XP, and it's how we get theirs.
function Comm:GreetNew()
    local hello = Protocol.EncodeHello()
    for _, route in ipairs(ns.Roster:Routes()) do
        local id = Comm.RouteId(route)
        if not greeted[id] and not self:IsExcluded(route) then
            greeted[id] = true
            Enqueue(route, hello, nil, true)
        end
    end
    if IsInGuild() and not greeted.guild then
        greeted.guild = true
        Enqueue({ kind = "guild" }, hello, nil, true)
    end

    -- Someone new in the party: everyone's status goes out again for them.
    local members, seen, newcomer = ns.Roster:PartyMembers(), {}, false
    for _, member in ipairs(members) do
        local key = Protocol.NameKey(member.name)
        seen[key] = true
        if not greetedParty[key] then newcomer = true end
    end
    greetedParty = seen
    if newcomer and self.PartyChannel() then Enqueue({ kind = "party" }, hello, nil, true) end
end

local function SendToKnown(text)
    for _, route in ipairs(ns.Roster:Routes()) do
        local id = Comm.RouteId(route)
        if known[id] and CanShare(route) then
            Enqueue(route, text, "S:" .. id)
        end
    end
    for _, kind in ipairs({ "guild", "party" }) do
        local route = { kind = kind }
        if CanShare(route) then Enqueue(route, text, "S:" .. kind) end
    end
end

function Comm:BroadcastStatus(text)
    SendToKnown(text)
end

local function HandleHello(route)
    if route.kind == "guild" or route.kind == "party" then
        -- One broadcast answers everyone, so many hellos at once cost one reply.
        if replyPending[route.kind] or not CanShare(route) then return end
        replyPending[route.kind] = true
        C_Timer.After(1 + math.random() * 3, function()
            replyPending[route.kind] = nil
            ns.Tracker:SendStatus()
        end)
    elseif CanShare(route) then
        Enqueue(route, ns.Tracker:EncodeOwnStatus(), "S:" .. Comm.RouteId(route))
    end
end

local function Dispatch(text, route, senderName, account)
    Comm.stats.received = Comm.stats.received + 1
    local msg = Protocol.Decode(text)
    if not msg then
        Comm.stats.rejected = Comm.stats.rejected + 1
        return
    end
    if route.kind == "bn" or route.kind == "whisper" then known[Comm.RouteId(route)] = true end

    if msg.kind == "H" then
        HandleHello(route)
    elseif msg.kind == "S" then
        -- The route identifies the sender, so a name in the message must agree with it.
        if not Protocol.SameName(msg.name, senderName) then
            Comm.stats.rejected = Comm.stats.rejected + 1
            return
        end
        ns.Tracker:OnStatus(msg, route, account)
    elseif msg.kind == "D" then
        if CanShare(route) then
            Enqueue(route, Protocol.EncodePong(msg.nonce))
        end
    elseif msg.kind == "E" and diag and diag.nonce == msg.nonce then
        table.insert(diag.replies, {
            label = KIND_LABELS[route.kind], name = senderName, delay = GetTime() - diag.startedAt,
        })
    end
end

local function OnAddonMessage(prefix, text, channel, sender)
    if ns.Plain(prefix) ~= Protocol.PREFIX then return end
    text, channel, sender = ns.Plain(text), ns.Plain(channel), ns.Plain(sender)
    if not (text and channel and sender) then return end
    if Protocol.SameName(sender, ns.Tracker:MyName()) then return end

    if channel == "GUILD" then
        Dispatch(text, { kind = "guild" }, sender)
    elseif channel == "PARTY" or channel == "INSTANCE_CHAT" then
        Dispatch(text, { kind = "party" }, sender)
    elseif channel == "WHISPER" then
        -- Only friends may whisper us data or get an answer back.
        if not ns.Roster:IsCharFriend(sender) then return end
        local target = sender:match("^[^%-]+")
        Dispatch(text, { kind = "whisper", target = target, name = target }, sender)
    end
end

local function OnBNetMessage(prefix, text, _, gameAccountID)
    if ns.Plain(prefix) ~= Protocol.PREFIX then return end
    text = ns.Plain(text)
    if not text or type(gameAccountID) ~= "number" then return end
    local name, account = ns.Roster:BNetSender(gameAccountID)
    if not name then return end
    Dispatch(text, { kind = "bn", id = gameAccountID, name = name, account = account }, name, account)
end

-- A whisper to someone who just logged off makes the client print "No player
-- named X". That text means nothing to the player here, so it's hidden for a
-- moment after each addon whisper. The text is read in a pcall because other
-- addons note chat text can be unreadable.
local notFoundPattern
local function MatchesNotFound(message)
    return message:find(notFoundPattern) ~= nil
end

local function FilterNotFound(_, _, message)
    if GetTime() - lastWhisperAt > WHISPER_ERROR_WINDOW then return false end
    if not notFoundPattern then
        if type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return false end
        notFoundPattern = ERR_CHAT_PLAYER_NOT_FOUND_S
            :gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
            :gsub("%%%%s", ".+")
    end
    local ok, matched = pcall(MatchesNotFound, message)
    return ok and matched or false
end

function Comm:Start()
    C_ChatInfo.RegisterAddonMessagePrefix(Protocol.PREFIX)
    ns.On("CHAT_MSG_ADDON", OnAddonMessage)
    if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid("BN_CHAT_MSG_ADDON") then
        ns.On("BN_CHAT_MSG_ADDON", OnBNetMessage)
    end
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter then pcall(addFilter, "CHAT_MSG_SYSTEM", FilterNotFound) end
end

--------------------------------------------------------------------------------
-- /dingus diag: what the client allows, and which routes actually reach someone
--------------------------------------------------------------------------------

function Comm:RunDiag()
    local given, second = UnitFullName("player")
    local routes = ns.Roster:Routes()
    ns.Print("Interface: " .. tostring(select(4, GetBuildInfo())))
    ns.Print("UnitName: " .. tostring(UnitName("player"))
        .. ", UnitFullName: " .. tostring(given) .. " / " .. tostring(second))
    ns.Print("Realm: " .. tostring(GetRealmName()) .. ", my name here: " .. tostring(ns.Tracker:MyName()))
    ns.Print("Messaging lockdown: " .. tostring(InLockdown())
        .. ", BN_CHAT_MSG_ADDON valid: " .. tostring(C_EventUtils and C_EventUtils.IsEventValid
            and C_EventUtils.IsEventValid("BN_CHAT_MSG_ADDON")))
    local s = self.stats
    ns.Print(("Sent %d, refused %d, throttled %d, received %d, rejected %d"):format(
        s.sent, s.refused, s.throttled, s.received, s.rejected))

    diag = { nonce = math.random(1, 1000000000), startedAt = GetTime(), replies = {} }
    local ping = Protocol.EncodePing(diag.nonce)
    local counts = { bn = 0, whisper = 0, guild = 0, party = 0 }
    for _, route in ipairs(routes) do
        if not self:IsExcluded(route) then
            counts[route.kind] = counts[route.kind] + 1
            Enqueue(route, ping)
        end
    end
    if IsInGuild() then
        counts.guild = 1
        Enqueue({ kind = "guild" }, ping)
    end
    if self.PartyChannel() then
        counts.party = 1
        Enqueue({ kind = "party" }, ping)
    end
    ns.Print(("Pinging: %d Battle.net, %d whisper, %d guild, %d party. Results in %d seconds."):format(
        counts.bn, counts.whisper, counts.guild, counts.party, DIAG_WAIT))

    local current = diag
    C_Timer.After(DIAG_WAIT, function()
        if #current.replies == 0 then
            ns.Print("No replies. Someone else must be online with Dingus, and sharing, for this to test a route.")
        end
        for _, reply in ipairs(current.replies) do
            ns.Print(("%s reached %s in %.1fs"):format(reply.label, reply.name, reply.delay))
        end
        if diag == current then diag = nil end
    end)
end
