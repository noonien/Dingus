local addonName, ns = ...

ns.addonName = addonName

ns.DEFAULTS = {
    -- Panel
    locked = false,
    width = 300,
    maxRows = 20,
    anchor = nil, -- { left, top } or, growing upwards, { left, bottom, up = true }
    barText = "full",
    rowHeight = "normal", -- normal, compact
    showDetails = false,
    collapsed = false, -- hidden down to the header, from the header's own button
    showPanel = "always", -- always, combat, instance, both (hidden in those), never
    fadeUntilHover = false,

    -- Rows
    sortBy = "level",
    ownBar = "never", -- never, others (when anyone else is listed), always
    showOffline = false,
    showMaxLevel = false,
    showGuild = false,
    showParty = true,

    -- Alerts
    alertWith = "both", -- off, toast, sound, both
    alertWho = "friends",

    -- Privacy
    shareFriends = true,
    shareGuild = true,
    shareParty = true,
    shareZone = true,
}

-- Edited in place, so each player needs their own table rather than a default.
local LISTS = { "collapsedSections", "pinned", "hidden", "excluded" }

local KEPT_ON_RESET = {
    anchor = true,
    pinned = true,
    hidden = true,
    excluded = true,
    shareFriends = true,
    shareGuild = true,
    shareParty = true,
    shareZone = true,
}

--- Only what the player has set is saved. Everything else reads from DEFAULTS,
--- so a changed default reaches everyone who hasn't set that option.
function ns.InitDB(db)
    db.settings = db.settings or {}
    db.peers = db.peers or {}
    for _, list in ipairs(LISTS) do
        db.settings[list] = db.settings[list] or {}
    end
    setmetatable(db.settings, { __index = ns.DEFAULTS })
    return db
end

--- Back to the defaults, apart from who the player listed, where they put the
--- panel, and what they agreed to share.
function ns.ResetSettings()
    local settings = ns.settings
    for key in pairs(settings) do
        if not KEPT_ON_RESET[key] then settings[key] = nil end
    end
    settings.collapsedSections = {}
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
