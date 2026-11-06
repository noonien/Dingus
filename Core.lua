local addonName, ns = ...

ns.addonName = addonName

ns.DEFAULTS = {
    -- Layout
    shown = true,
    collapsedSections = {},
    locked = false,
    width = 300,
    barHeight = 22,
    spacing = 1,
    growUp = false,
    maxRows = 20,
    anchor = nil, -- { left, top, bottom }, the panel's edges

    -- Look
    barColor = "class",
    font = "default",
    fontSize = 12,
    opacity = 0,
    barText = "full",

    -- Rows
    sortBy = "level",
    showSelf = false,
    showOffline = false,
    showMaxLevel = false,
    showGuild = false,
    showParty = true,

    -- Visibility
    hideInCombat = false,
    hideInInstance = false,
    hideWhenAlone = false,
    fadeUntilHover = false,

    -- Alerts
    alertToast = false,
    alertSound = false,
    alertWho = "all",

    -- Privacy
    sharing = true,
    shareFriends = true,
    shareGuild = true,
    shareParty = true,
    shareZone = false,

    -- Per-person lists, keyed by peer key
    pinned = {},
    hidden = {},
    excluded = {},
}

local function CopyDefault(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = CopyDefault(v) end
    return copy
end

function ns.InitDB(db)
    db.settings = db.settings or {}
    db.peers = db.peers or {}
    for key, value in pairs(ns.DEFAULTS) do
        if db.settings[key] == nil then db.settings[key] = CopyDefault(value) end
    end
    return db
end

local function CopyPlain(value)
    if type(value) ~= "string" or value == "" then return nil end
    return value .. ""
end

--- A plain copy of a string from the client, or nil. Blackthornes_Equipment
--- notes the client can hand addons names that raise when used, so the test
--- and the copy happen inside the pcall.
function ns.Plain(value)
    local ok, copy = pcall(CopyPlain, value)
    return ok and copy or nil
end

function ns.Print(text)
    print("|cff7fb2e5Dingus:|r " .. text)
end

local listeners = {}
local frame = CreateFrame("Frame")

--- Listen to a game event. Several modules can share one event.
function ns.On(event, handler)
    if not listeners[event] then
        listeners[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(listeners[event], handler)
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            self:UnregisterEvent("ADDON_LOADED")
            DingusAddonDB = DingusAddonDB or {}
            ns.db = ns.InitDB(DingusAddonDB)
            ns.settings = ns.db.settings
        end
        return
    end
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        ns.Comm:Start()
        ns.Roster:Start()
        ns.Tracker:Start()
        ns.UI:Start()
        ns.Options:Start()
        return
    end
    local handlers = listeners[event]
    if handlers then
        for i = 1, #handlers do handlers[i](...) end
    end
end)
