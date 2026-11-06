-- Settings panel and slash commands. The controls are flat and built here, so
-- they match the main panel and don't depend on Blizzard's option templates.

local _, ns = ...

local Options = {}
ns.Options = Options

local FLAT = "Interface\\Buttons\\WHITE8X8"
local COLUMN_WIDTH = 280
local COLUMN_GAP = 30
local LABEL_WIDTH = 100
local ROW_HEIGHT = 28
local HEADING_HEIGHT = 34
local CONTROL_HEIGHT = 22
local RESET_ALL_WIDTH = 130
local RESET_SIZE = 16
local CHIP_HEIGHT = 24
local CHIP_GAP = 1
local MENU_ITEM_HEIGHT = 22
local MENU_PADDING = 3
local SCROLL_STEP = 60

local CONTROL_COLOR = { 0.11, 0.12, 0.15 }
local CHIP_ON_COLOR = { 0.18, 0.26, 0.35 }
local MENU_COLOR = { 0.14, 0.15, 0.18 }
local ACCENT = { 0.5, 0.7, 0.9 }
local TEXT = { 1, 1, 1 }
local TEXT_MUTED = { 0.79, 0.81, 0.84 }
local TEXT_DISABLED = { 0.55, 0.58, 0.61 }

local refreshers = {}
local category
local menu

local function RefreshControls()
    for _, refresh in ipairs(refreshers) do refresh() end
end

--- A value in the saved settings, as opposed to one read from the defaults.
local function IsSet(key)
    return rawget(ns.settings, key) ~= nil
end

local function Set(key, value, onChange)
    ns.settings[key] = value
    ns.UI:ApplySettings()
    RefreshControls()
    if onChange then onChange() end
end

local function OnPrivacyChanged()
    -- Sends as soon as the limit allows, so a changed zone setting reaches friends quickly.
    ns.Tracker:SendStatus()
end

local function NewLabel(parent, text, x, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetText(text)
    return label
end

local function Flat(parent, layer, color, a)
    local texture = parent:CreateTexture(nil, layer)
    texture:SetTexture(FLAT)
    texture:SetVertexColor(color[1], color[2], color[3], a or 1)
    return texture
end

local function AddTooltip(widget, text)
    if not text then return end
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- An arrow curling back on itself, drawn so it needs no art.
local function DrawResetArrow(button)
    local center = RESET_SIZE / 2
    local radius = 5
    local steps = 7
    local function Point(step)
        local angle = math.rad(50 + step * 270 / steps)
        return center + radius * math.cos(angle), radius * math.sin(angle) - center
    end
    local function Stroke(x1, y1, x2, y2)
        local line = button:CreateLine(nil, "ARTWORK")
        line:SetThickness(1.2)
        line:SetColorTexture(TEXT_DISABLED[1], TEXT_DISABLED[2], TEXT_DISABLED[3])
        line:SetStartPoint("TOPLEFT", button, x1, y1)
        line:SetEndPoint("TOPLEFT", button, x2, y2)
    end
    for step = 0, steps - 1 do
        local x1, y1 = Point(step)
        local x2, y2 = Point(step + 1)
        Stroke(x1, y1, x2, y2)
    end
    local tipX, tipY = Point(0)
    Stroke(tipX, tipY, tipX, tipY + 4)
    Stroke(tipX, tipY, tipX - 4, tipY)
end

--- Sits at the end of a row, and shows while any of its settings is saved.
local function ResetButton(parent, x, y, keys, defaultText, onChange)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(RESET_SIZE, RESET_SIZE)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x + COLUMN_WIDTH - RESET_SIZE, y - 2)
    DrawResetArrow(button)
    Flat(button, "HIGHLIGHT", TEXT, 0.08):SetAllPoints()
    AddTooltip(button, "Back to the default: " .. defaultText)
    button:SetScript("OnClick", function()
        for _, key in ipairs(keys) do ns.settings[key] = nil end
        ns.UI:ApplySettings()
        RefreshControls()
        if onChange then onChange() end
    end)
    table.insert(refreshers, function()
        local shown = false
        for _, key in ipairs(keys) do shown = shown or IsSet(key) end
        button:SetShown(shown)
    end)
end

local function Checkbox(parent, x, y, text, key, tooltip, onChange)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetSize(COLUMN_WIDTH - RESET_SIZE - 6, 20)

    local box = Flat(button, "BACKGROUND", CONTROL_COLOR)
    box:SetSize(16, 16)
    box:SetPoint("LEFT")
    local mark = Flat(button, "ARTWORK", ACCENT)
    mark:SetSize(10, 10)
    mark:SetPoint("CENTER", box, "CENTER")

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", box, "RIGHT", 8, 0)
    label:SetText(text)

    button:SetScript("OnClick", function() Set(key, not ns.settings[key], onChange) end)
    AddTooltip(button, tooltip)
    table.insert(refreshers, function() mark:SetShown(ns.settings[key] and true or false) end)
    ResetButton(parent, x, y, { key }, ns.DEFAULTS[key] and "on" or "off", onChange)
end

--------------------------------------------------------------------------------
-- Dropdowns
--------------------------------------------------------------------------------

local function CloseMenu()
    if menu then menu:Hide() end
end

--- One list, shared by every dropdown. A screen-wide button sits under it, so
--- a click anywhere else closes it.
local function BuildMenu()
    menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:Hide()
    menu.items = {}
    Flat(menu, "BACKGROUND", MENU_COLOR):SetAllPoints()

    local catcher = CreateFrame("Button", nil, menu)
    catcher:SetFrameLevel(menu:GetFrameLevel())
    catcher:SetAllPoints(UIParent)
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:SetScript("OnClick", CloseMenu)
end

local function MenuItem(index)
    local item = menu.items[index]
    if item then return item end
    item = CreateFrame("Button", nil, menu)
    item:SetFrameLevel(menu:GetFrameLevel() + 2)
    item:SetHeight(MENU_ITEM_HEIGHT)
    item:SetPoint("TOPLEFT", menu, "TOPLEFT", 0, -MENU_PADDING - (index - 1) * MENU_ITEM_HEIGHT)
    item:SetPoint("TOPRIGHT", menu, "TOPRIGHT", 0, -MENU_PADDING - (index - 1) * MENU_ITEM_HEIGHT)
    Flat(item, "HIGHLIGHT", TEXT, 0.08):SetAllPoints()
    item.mark = Flat(item, "ARTWORK", ACCENT)
    item.mark:SetSize(5, 5)
    item.mark:SetPoint("LEFT", item, "LEFT", 8, 0)
    item.label = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    item.label:SetPoint("LEFT", item, "LEFT", 20, 0)
    menu.items[index] = item
    return item
end

local function OpenMenu(owner, choices, current, onPick)
    if not menu then BuildMenu() end
    if menu:IsShown() and menu.owner == owner then
        CloseMenu()
        return
    end
    menu.owner = owner
    for index, choice in ipairs(choices) do
        local item = MenuItem(index)
        local selected = choice.id == current
        item.label:SetText(choice.label)
        local color = selected and TEXT or TEXT_MUTED
        item.label:SetTextColor(color[1], color[2], color[3])
        item.mark:SetShown(selected)
        item:SetScript("OnClick", function()
            CloseMenu()
            onPick(choice.id)
        end)
        item:Show()
    end
    for index = #choices + 1, #menu.items do menu.items[index]:Hide() end
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(owner:GetWidth())
    menu:SetHeight(#choices * MENU_ITEM_HEIGHT + MENU_PADDING * 2)
    menu:Show()
end

local function LabelFor(choices, id)
    for _, choice in ipairs(choices) do
        if choice.id == id then return choice.label end
    end
    return choices[1].label
end

local function Dropdown(parent, x, y, text, key, choices, tooltip, isEnabled)
    local label = NewLabel(parent, text, x, y - 3)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x + LABEL_WIDTH, y)
    button:SetSize(COLUMN_WIDTH - LABEL_WIDTH - RESET_SIZE - 6, CONTROL_HEIGHT)

    Flat(button, "BACKGROUND", CONTROL_COLOR):SetAllPoints()
    Flat(button, "HIGHLIGHT", TEXT, 0.08):SetAllPoints()
    local value = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("LEFT", button, "LEFT", 8, 0)
    for _, startX in ipairs({ -14, -8 }) do
        local line = button:CreateLine(nil, "ARTWORK")
        line:SetThickness(1.2)
        line:SetColorTexture(TEXT_DISABLED[1], TEXT_DISABLED[2], TEXT_DISABLED[3])
        line:SetStartPoint("RIGHT", button, startX, 2)
        line:SetEndPoint("RIGHT", button, -11, -1)
    end

    button:SetScript("OnClick", function()
        OpenMenu(button, choices, ns.settings[key], function(id) Set(key, id) end)
    end)
    AddTooltip(button, tooltip)
    table.insert(refreshers, function()
        local enabled = not isEnabled or isEnabled()
        button:SetEnabled(enabled)
        value:SetText(LabelFor(choices, ns.settings[key]))
        local color = enabled and TEXT or TEXT_DISABLED
        value:SetTextColor(color[1], color[2], color[3])
        local labelColor = enabled and TEXT or TEXT_DISABLED
        label:SetTextColor(labelColor[1], labelColor[2], labelColor[3])
    end)
    ResetButton(parent, x, y, { key }, LabelFor(choices, ns.DEFAULTS[key]))
end

--------------------------------------------------------------------------------
-- Chips, buttons and layout
--------------------------------------------------------------------------------

--- A row of on/off toggles under one label, with one reset for the row.
local function Chips(parent, x, y, text, chips, onChange)
    NewLabel(parent, text, x, y - 3)
    local total = COLUMN_WIDTH - RESET_SIZE - 6
    local width = (total - CHIP_GAP * (#chips - 1)) / #chips
    local keys, defaults = {}, {}
    for index, chip in ipairs(chips) do
        keys[index] = chip.key
        if ns.DEFAULTS[chip.key] then defaults[#defaults + 1] = chip.label end

        local button = CreateFrame("Button", nil, parent)
        button:SetSize(width, CHIP_HEIGHT)
        button:SetPoint("TOPLEFT", parent, "TOPLEFT", x + (index - 1) * (width + CHIP_GAP), y - 24)
        local background = Flat(button, "BACKGROUND", CONTROL_COLOR)
        background:SetAllPoints()
        Flat(button, "HIGHLIGHT", TEXT, 0.08):SetAllPoints()
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("CENTER")
        label:SetText(chip.label)
        button:SetScript("OnClick", function() Set(chip.key, not ns.settings[chip.key], onChange) end)
        AddTooltip(button, chip.tooltip)
        table.insert(refreshers, function()
            local on = ns.settings[chip.key]
            local fill = on and CHIP_ON_COLOR or CONTROL_COLOR
            background:SetVertexColor(fill[1], fill[2], fill[3])
            local color = on and TEXT or TEXT_DISABLED
            label:SetTextColor(color[1], color[2], color[3])
        end)
    end
    local defaultText = #defaults > 0 and table.concat(defaults, ", ") or "none"
    ResetButton(parent, x, y, keys, defaultText, onChange)
end

--- getLabel returns the button's text and whether it has anything to do.
local function ActionButton(parent, x, y, getLabel, tooltip, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetSize(COLUMN_WIDTH - RESET_SIZE - 6, CONTROL_HEIGHT)
    Flat(button, "BACKGROUND", CONTROL_COLOR):SetAllPoints()
    Flat(button, "HIGHLIGHT", TEXT, 0.08):SetAllPoints()
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("CENTER")
    button:SetScript("OnClick", function()
        onClick()
        RefreshControls()
    end)
    AddTooltip(button, tooltip)
    table.insert(refreshers, function()
        local text, enabled = getLabel()
        label:SetText(text)
        button:SetEnabled(enabled)
        local color = enabled and TEXT or TEXT_DISABLED
        label:SetTextColor(color[1], color[2], color[3])
    end)
end

--- Lays out a column top to bottom and hands each control its position.
local function Column(parent, x)
    local y = -4
    local column = {}
    function column:Heading(text)
        y = y - 8
        local heading = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heading:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        heading:SetText(text)
        heading:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
        y = y - HEADING_HEIGHT + 8
    end
    function column:Check(...) Checkbox(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Pick(...) Dropdown(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Chips(...) Chips(parent, x, y, ...) y = y - 24 - CHIP_HEIGHT - 6 end
    function column:Action(...) ActionButton(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Bottom() return y end
    return column
end

local function CountOf(list)
    local count = 0
    for key in pairs(list) do
        -- Someone on Battle.net has a second key for their account.
        if not tostring(key):find("^account:") then count = count + 1 end
    end
    return count
end

local function BuildPanel()
    local panel = CreateFrame("Frame")
    panel:Hide()

    local titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    titleText:SetText("Dingus")

    local reset = CreateFrame("Button", nil, panel)
    reset:SetSize(RESET_ALL_WIDTH, CONTROL_HEIGHT)
    reset:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -12)
    Flat(reset, "BACKGROUND", CONTROL_COLOR):SetAllPoints()
    Flat(reset, "HIGHLIGHT", TEXT, 0.08):SetAllPoints()
    local resetLabel = reset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    resetLabel:SetPoint("CENTER")
    resetLabel:SetText("Reset to defaults")
    AddTooltip(reset, "Pinned, hidden and excluded players, the panel's position and your sharing settings stay as they are.")
    reset:SetScript("OnClick", function() StaticPopup_Show("DINGUS_RESET") end)

    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -44)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 8)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(COLUMN_WIDTH * 2 + COLUMN_GAP, 1)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        CloseMenu()
        local range = self:GetVerticalScrollRange()
        local target = self:GetVerticalScroll() - delta * SCROLL_STEP
        self:SetVerticalScroll(math.max(0, math.min(range, target)))
    end)

    local left = Column(content, 0)
    left:Heading("Panel")
    left:Pick("Bar text", "barText", {
        { id = "full", label = "Level, XP and %" },
        { id = "percent", label = "% only" },
        { id = "level", label = "Level only" },
        { id = "none", label = "Name only" },
    })
    left:Pick("Row height", "rowHeight", {
        { id = "normal", label = "Normal" },
        { id = "compact", label = "Compact" },
    })
    left:Check("Show a details line", "showDetails", "Adds zone, XP per hour and time to the next level under each bar.")
    left:Pick("Show panel", "showPanel", {
        { id = "always", label = "Always" },
        { id = "combat", label = "Out of combat" },
        { id = "instance", label = "Out of instances" },
        { id = "both", label = "Out of both" },
        { id = "never", label = "Never" },
    })
    left:Check("Fade until hovered", "fadeUntilHover")
    left:Check("Lock size and position", "locked",
        "When unlocked, drag the panel to move it, and hover it and drag its corner or edges to resize it. Double-click the corner to reset the size.")

    left:Heading("Level-up alerts")
    left:Pick("Alert with", "alertWith", {
        { id = "off", label = "Off" },
        { id = "toast", label = "Toast" },
        { id = "sound", label = "Sound" },
        { id = "both", label = "Toast and sound" },
    })
    left:Pick("Alert for", "alertWho", {
        { id = "all", label = "Everyone" },
        { id = "friends", label = "Friends only" },
        { id = "pinned", label = "Pinned only" },
    }, nil, function() return ns.settings.alertWith ~= "off" end)

    local right = Column(content, COLUMN_WIDTH + COLUMN_GAP)
    right:Heading("Who's listed")
    right:Pick("Sort by", "sortBy", {
        { id = "level", label = "Level" },
        { id = "progress", label = "Level progress" },
        { id = "name", label = "Name" },
        { id = "recent", label = "Recent activity" },
    })
    right:Pick("My own bar", "ownBar", {
        { id = "never", label = "Never" },
        { id = "others", label = "With others" },
        { id = "always", label = "Always" },
    })
    right:Chips("Also list", {
        { key = "showParty", label = "Party" },
        { key = "showGuild", label = "Guild" },
        { key = "showOffline", label = "Offline" },
        { key = "showMaxLevel", label = "Max level" },
    })
    right:Action(function()
        local count = CountOf(ns.settings.hidden)
        if count == 0 then return "No hidden players", false end
        return ("Show %d hidden |4player:players; again"):format(count), true
    end, "Lists everyone you hid with the row's right-click menu again.", function()
        ns.settings.hidden = {}
        ns.UI:ApplySettings()
    end)

    right:Heading("Sharing")
    right:Chips("Share my XP with", {
        { key = "shareFriends", label = "Friends" },
        { key = "shareGuild", label = "Guild",
            tooltip = "A guild message reaches every guildmate running Dingus, including anyone you stopped sharing with." },
        { key = "shareParty", label = "Party",
            tooltip = "A party message reaches every member running Dingus, including anyone you stopped sharing with." },
    }, OnPrivacyChanged)
    right:Check("Include my zone", "shareZone", "Adds your current zone to what you share.", OnPrivacyChanged)
    right:Action(function()
        local count = CountOf(ns.settings.excluded)
        if count == 0 then return "Sharing with everyone", false end
        return ("Share with %d excluded |4player:players; again"):format(count), true
    end, "Clears every person you stopped sharing with.", function()
        ns.settings.excluded = {}
        OnPrivacyChanged()
    end)

    content:SetHeight(-math.min(left:Bottom(), right:Bottom()) + 8)
    panel:SetScript("OnShow", RefreshControls)
    panel:SetScript("OnHide", CloseMenu)
    return panel
end

function Options:Open()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    else
        ns.Print("The settings panel isn't available on this client.")
    end
end

local function PrintHelp()
    ns.Print("/dingus: open settings (or right-click a section header)")
    ns.Print("/dingus demo: fill the panel with sample players")
    ns.Print("/dingus reset: move the panel back to its starting position")
    ns.Print("/dingus diag: test which message routes reach other players")
end

local function HandleSlash(input)
    local command = (input or ""):lower():match("^%s*(%S*)")
    if command == "" or command == "options" or command == "config" then
        Options:Open()
    elseif command == "demo" then
        ns.Print(ns.Tracker:ToggleDemo() and "Demo on. /dingus demo turns it off." or "Demo off.")
    elseif command == "reset" then
        ns.UI:ResetPosition()
    elseif command == "diag" then
        ns.Comm:RunDiag()
    else
        PrintHelp()
    end
end

function Options:Start()
    SLASH_DINGUS1 = "/dingus"
    SlashCmdList.DINGUS = HandleSlash

    StaticPopupDialogs.DINGUS_RESET = {
        text = "Reset Dingus to its default settings?\n\nPinned, hidden and excluded players, the panel's position and your sharing settings stay as they are.",
        button1 = YES,
        button2 = NO,
        OnAccept = function()
            ns.ResetSettings()
            ns.UI:ApplySettings()
            RefreshControls()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local panel = BuildPanel()
        category = Settings.RegisterCanvasLayoutCategory(panel, "Dingus")
        Settings.RegisterAddOnCategory(category)
    end
end
