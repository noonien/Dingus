-- Who the player's friends and guildmates are, who is online, and how to reach them.

local _, ns = ...

local Roster = {}
ns.Roster = Roster

local Protocol = ns.Protocol
local Plain = ns.Plain

local REFRESH_DELAY = 1
local GUILD_REQUEST_SECONDS = 30 -- a backstop: presence events ask sooner
local GUILD_REQUEST_MIN_GAP = 10 -- the server ignores requests closer together than about this

local routes = {}       -- every online friend we can send to
local accounts = {}     -- battleTag -> { accountName, chars = { names online } }
local charFriends = {}  -- name key -> { name, connected }
local byGameAccount = {} -- gameAccountID -> { name, account }
local guildOnline = {}  -- first name -> online
local party = {}        -- { name, connected }, the other members of a party, not a raid
local guildName
local refreshPending = false
local lastGuildRequest
local guildRequestPending = false

local function Read(fn, ...)
    if not fn then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function ScanBattleNet(newRoutes, newAccounts, newByGameAccount)
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return end
    local total = Read(BNGetNumFriends) or 0
    local myName = ns.Tracker:MyName()
    for i = 1, total do
        local info = Read(C_BattleNet.GetFriendAccountInfo, i)
        local tag = info and Plain(info.battleTag)
        if tag then
            local account = { accountName = Plain(info.accountName), chars = {} }
            newAccounts[tag] = account
            local count = Read(C_BattleNet.GetFriendNumGameAccounts, i) or 0
            for j = 1, count do
                local game = Read(C_BattleNet.GetFriendGameAccountInfo, i, j)
                local id = game and game.gameAccountID
                if id and game.isOnline and game.clientProgram == BNET_CLIENT_WOW
                    and (game.wowProjectID == nil or game.wowProjectID == WOW_PROJECT_ID) then
                    local name = Plain(game.characterName)
                    if name and not Protocol.SameName(name, myName) then
                        account.chars[#account.chars + 1] = name
                        newByGameAccount[id] = { name = name, account = tag }
                        newRoutes[#newRoutes + 1] = { kind = "bn", id = id, name = name, account = tag }
                    end
                end
            end
        end
    end
end

local function ScanCharacterFriends(newRoutes, newCharFriends)
    if not (C_FriendList and C_FriendList.GetNumFriends) then return end
    local total = Read(C_FriendList.GetNumFriends) or 0
    for i = 1, total do
        local info = Read(C_FriendList.GetFriendInfoByIndex, i)
        local raw = info and Plain(info.name)
        local name = raw and raw:match("^[^%-]+")
        local key = Protocol.NameKey(name)
        if key then
            newCharFriends[key] = { name = name, connected = info.connected and true or false }
            if info.connected then
                -- Skip whispers to someone Battle.net already reaches.
                local covered = false
                for _, route in ipairs(newRoutes) do
                    if Protocol.SameName(route.name, name) then covered = true break end
                end
                if not covered then
                    newRoutes[#newRoutes + 1] = { kind = "whisper", target = name, name = name }
                end
            end
        end
    end
end

local function ScanGuild()
    local newOnline = {}
    guildName = IsInGuild() and Plain(Read(GetGuildInfo, "player")) or nil
    if guildName then
        local total = Read(GetNumGuildMembers) or 0
        for i = 1, total do
            local ok, name, _, _, _, _, _, _, _, online = pcall(GetGuildRosterInfo, i)
            local first = ok and Protocol.FirstToken(Plain(name))
            if first then newOnline[first] = newOnline[first] or (online and true or false) end
        end
    end
    guildOnline = newOnline
end

local function ReadParty()
    if IsInRaid() or not IsInGroup() then return {} end
    local members = {}
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local name = ns.Tracker.ReadFullName(unit)
            if not name then error("unreadable name") end
            members[#members + 1] = { name = name, connected = UnitIsConnected(unit) and true or false }
        end
    end
    return members
end

function Roster:Refresh()
    local newRoutes, newAccounts, newCharFriends, newByGameAccount = {}, {}, {}, {}
    -- Dungeons can make names unreadable (Blackthornes_Equipment), so the last
    -- good list stands until they can be read again.
    local ok, members = pcall(ReadParty)
    if ok then party = members end
    ScanBattleNet(newRoutes, newAccounts, newByGameAccount)
    ScanCharacterFriends(newRoutes, newCharFriends)
    ScanGuild()
    routes, accounts, charFriends, byGameAccount = newRoutes, newAccounts, newCharFriends, newByGameAccount
end

local function ScheduleRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(REFRESH_DELAY, function()
        refreshPending = false
        Roster:Refresh()
        ns.Comm:GreetNew()
        ns.UI:Refresh()
    end)
end

local function SendGuildRequest()
    lastGuildRequest = GetTime()
    pcall(C_GuildInfo.GuildRoster)
end

--- Asks for a fresh guild roster, which arrives as GUILD_ROSTER_UPDATE. A request
--- too soon after the last waits rather than being lost to the server's limit.
local function RequestGuild()
    if guildRequestPending or not (IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster) then return end
    local wait = lastGuildRequest and lastGuildRequest + GUILD_REQUEST_MIN_GAP - GetTime() or 0
    if wait <= 0 then
        SendGuildRequest()
        return
    end
    guildRequestPending = true
    C_Timer.After(wait, function()
        guildRequestPending = false
        SendGuildRequest()
    end)
end

--- Registering an event the client doesn't have raises an error.
local function OnIfValid(event, handler)
    if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid(event) then
        ns.On(event, handler)
    end
end

function Roster:Start()
    for _, event in ipairs({
        "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_LIST_SIZE_CHANGED", "BN_CONNECTED",
        "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "PLAYER_ENTERING_WORLD",
        "GROUP_ROSTER_UPDATE", "UNIT_CONNECTION",
    }) do
        ns.On(event, ScheduleRefresh)
    end
    OnIfValid("BN_FRIEND_ACCOUNT_ONLINE", ScheduleRefresh)
    OnIfValid("BN_FRIEND_ACCOUNT_OFFLINE", ScheduleRefresh)
    -- Also fires for communities, which the request limit keeps cheap.
    OnIfValid("CLUB_MEMBER_PRESENCE_UPDATED", RequestGuild)
    if C_FriendList and C_FriendList.ShowFriends then pcall(C_FriendList.ShowFriends) end
    RequestGuild()
    C_Timer.NewTicker(GUILD_REQUEST_SECONDS, RequestGuild)
    ScheduleRefresh()
end

function Roster:Routes()
    return routes
end

function Roster:PartyMembers()
    return party
end

local function FindPartyMember(name)
    for _, member in ipairs(party) do
        if Protocol.SameName(member.name, name) then return member end
    end
end

function Roster:GuildName()
    -- GetGuildInfo can be empty just after login, before the first scan has it.
    if not guildName and IsInGuild() then guildName = Plain(Read(GetGuildInfo, "player")) end
    return guildName
end

--- The character and Battle.net account behind a game account, or nil.
function Roster:BNetSender(gameAccountID)
    local entry = byGameAccount[gameAccountID]
    if not entry then
        self:Refresh()
        entry = byGameAccount[gameAccountID]
    end
    if entry then return entry.name, entry.account end
end

local function FindCharFriend(name)
    local key = Protocol.NameKey(name)
    if not key then return nil end
    if charFriends[key] then return charFriends[key] end
    for _, friend in pairs(charFriends) do
        if Protocol.SameName(friend.name, name) then return friend end
    end
end

function Roster:IsCharFriend(name)
    return FindCharFriend(name) ~= nil
end

function Roster:IsFriend(peer)
    return (peer.account and accounts[peer.account] ~= nil) or FindCharFriend(peer.name) ~= nil
end

--- "party", "friends", "guild", or nil once this person is none of those.
--- Each person is listed once, in the first of those that applies. With party
--- members not shown, someone in the party falls through to the others.
function Roster:GroupOf(peer)
    if ns.settings.showParty and FindPartyMember(peer.name) then return "party" end
    if self:IsFriend(peer) then return "friends" end
    if guildName and peer.guild == guildName then return "guild" end
    return nil
end

--- true or false when the roster knows, nil when it doesn't.
function Roster:OnlineState(peer)
    local member = FindPartyMember(peer.name)
    if member then return member.connected end
    local account = peer.account and accounts[peer.account]
    if account then
        for _, name in ipairs(account.chars) do
            if Protocol.SameName(name, peer.name) then return true end
        end
        return false
    end
    local friend = FindCharFriend(peer.name)
    if friend then return friend.connected end
    return guildOnline[Protocol.FirstToken(peer.name)]
end

--- The Battle.net name for opening a whisper, valid only this session.
function Roster:AccountName(tag)
    local account = tag and accounts[tag]
    return account and account.accountName or nil
end
