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
    showSelf = true,
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
    if (db.schema or 1) < 2 then
        -- The panel header is gone.
        db.settings.collapsed = nil
        db.schema = 2
    end
    if db.schema < 3 then
        -- Thick bars with their text inside: move sizes left at their old defaults.
        local s = db.settings
        if s.width == 268 then s.width = nil end
        if s.barHeight == 24 then s.barHeight = nil end
        if s.spacing == 2 or s.spacing == 4 then s.spacing = nil end
        if s.fontSize == 13 then s.fontSize = nil end
        db.schema = 3
    end
    if db.schema < 4 then
        -- The panel no longer has a background; the slider can bring one back.
        db.settings.opacity = nil
        db.schema = 4
    end
    if db.schema < 5 then
        -- Guildmates were on by default in the first versions, so a saved "on" isn't a choice.
        db.settings.showGuild = nil
        db.schema = 5
    end
    if db.schema < 6 then
        -- /dingus used to hide the panel without saying so. It's a checkbox now, so start visible.
        db.settings.shown = nil
        db.schema = 6
    end
    if db.schema < 7 then
        -- The own bar was off by default, which left the panel empty with nobody else listed.
        db.settings.showSelf = nil
        db.schema = 7
    end
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
    print("|cff7fb2e5Ding:|r " .. text)
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
