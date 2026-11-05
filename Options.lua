-- Settings panel and slash commands. The controls are flat and built here, so
-- they match the main panel and don't depend on Blizzard's option templates.

local _, ns = ...

local Options = {}
ns.Options = Options

local FLAT = "Interface\\Buttons\\WHITE8X8"
local COLUMN_WIDTH = 280
local COLUMN_GAP = 30
local ROW_HEIGHT = 28
local HEADING_HEIGHT = 34
local SCROLL_STEP = 60

local refreshers = {}
local category

local function Set(key, value)
    ns.settings[key] = value
    ns.UI:ApplySettings()
end

local function OnPrivacyChanged()
    -- Sends right away, so a changed zone setting reaches friends quickly.
    ns.Tracker:SendStatus()
end

local function NewLabel(parent, text, x, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetText(text)
    return label
end

local function Flat(parent, layer, r, g, b, a)
    local texture = parent:CreateTexture(nil, layer)
    texture:SetTexture(FLAT)
    texture:SetVertexColor(r, g, b, a or 1)
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

local function Checkbox(parent, x, y, text, key, tooltip, onChange)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetSize(COLUMN_WIDTH, 20)

    local box = Flat(button, "BACKGROUND", 0.11, 0.12, 0.15)
    box:SetSize(16, 16)
    box:SetPoint("LEFT")
    local mark = Flat(button, "ARTWORK", 0.5, 0.7, 0.9)
    mark:SetSize(10, 10)
    mark:SetPoint("CENTER", box, "CENTER")

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", box, "RIGHT", 8, 0)
    label:SetText(text)

    local function Refresh() mark:SetShown(ns.settings[key] and true or false) end
    button:SetScript("OnClick", function()
        Set(key, not ns.settings[key])
        Refresh()
        if onChange then onChange() end
    end)
    AddTooltip(button, tooltip)
    table.insert(refreshers, Refresh)
end

local function Slider(parent, x, y, text, key, minimum, maximum, step, format)
    local label = NewLabel(parent, text, x, y - 3)
    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 240, y - 3)

    local slider = CreateFrame("Slider", nil, parent)
    slider:EnableMouse(true)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 110, y - 2)
    slider:SetSize(120, 14)
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local track = Flat(slider, "BACKGROUND", 0.11, 0.12, 0.15)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)

    slider:SetThumbTexture(FLAT)
    local thumb = slider:GetThumbTexture()
    thumb:SetVertexColor(0.5, 0.7, 0.9)
    thumb:SetSize(8, 14)

    local function Show(current)
        value:SetText(format and format(current) or tostring(current))
    end
    local updating = false
    slider:SetScript("OnValueChanged", function(_, current)
        if updating then return end
        current = math.floor(current / step + 0.5) * step
        Show(current)
        Set(key, current)
    end)
    table.insert(refreshers, function()
        updating = true
        slider:SetValue(ns.settings[key])
        updating = false
        Show(ns.settings[key])
    end)
    return label
end

--- A button that steps through choices: left click for next, right click for previous.
local function Cycler(parent, x, y, text, key, choices, tooltip)
    NewLabel(parent, text, x, y - 3)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 110, y)
    button:SetSize(150, 20)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    Flat(button, "BACKGROUND", 0.11, 0.12, 0.15):SetAllPoints()
    local highlight = Flat(button, "HIGHLIGHT", 1, 1, 1, 0.08)
    highlight:SetAllPoints()
    local value = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("CENTER")

    local function Refresh()
        for _, choice in ipairs(choices) do
            if choice.id == ns.settings[key] then
                value:SetText(choice.label)
                return
            end
        end
        value:SetText(choices[1].label)
    end
    button:SetScript("OnClick", function(_, mouse)
        local index = 1
        for i, choice in ipairs(choices) do
            if choice.id == ns.settings[key] then index = i end
        end
        index = index + (mouse == "RightButton" and -1 or 1)
        if index > #choices then index = 1 elseif index < 1 then index = #choices end
        Set(key, choices[index].id)
        Refresh()
    end)
    AddTooltip(button, tooltip)
    table.insert(refreshers, Refresh)
end

local function ActionButton(parent, x, y, text, tooltip, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetSize(COLUMN_WIDTH - 20, 22)
    Flat(button, "BACKGROUND", 0.11, 0.12, 0.15):SetAllPoints()
    Flat(button, "HIGHLIGHT", 1, 1, 1, 0.08):SetAllPoints()
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("CENTER")
    label:SetText(text)
    button:SetScript("OnClick", onClick)
    AddTooltip(button, tooltip)
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
        y = y - HEADING_HEIGHT + 8
    end
    function column:Check(...) Checkbox(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Slide(...) Slider(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Cycle(...) Cycler(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Action(...) ActionButton(parent, x, y, ...) y = y - ROW_HEIGHT end
    function column:Bottom() return y end
    return column
end

local function Percent(value)
    return ("%d%%"):format(value * 100 + 0.5)
end

local function BuildPanel()
    local panel = CreateFrame("Frame")
    panel:Hide()

    local titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    titleText:SetText("Ding")

    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -44)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 8)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(COLUMN_WIDTH * 2 + COLUMN_GAP, 1)
    scroll:SetScrollChild(content)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange()
        local target = self:GetVerticalScroll() - delta * SCROLL_STEP
        self:SetVerticalScroll(math.max(0, math.min(range, target)))
    end)

    local left = Column(content, 0)
    left:Heading("Layout")
    left:Slide("Width", "width", 180, 420, 4)
    left:Slide("Row height", "barHeight", 16, 36, 1)
    left:Slide("Row spacing", "spacing", 0, 8, 1)
    left:Slide("Maximum rows", "maxRows", 3, 40, 1)
    left:Check("Grow upwards", "growUp", "Keeps the panel's bottom edge in place, so new rows push it upwards.")
    left:Check("Lock position", "locked")

    left:Heading("Look")
    left:Cycle("Bar colour", "barColor", ns.BAR_COLORS)
    left:Cycle("Font", "font", ns.FONTS)
    left:Slide("Font size", "fontSize", 9, 18, 1)
    left:Slide("Background", "opacity", 0, 1, 0.02, Percent)
    left:Cycle("Bar text", "barText", {
        { id = "full", label = "Level, XP and %" },
        { id = "percent", label = "% only" },
        { id = "level", label = "Level only" },
        { id = "none", label = "Name only" },
    })

    left:Heading("Level-up alerts")
    left:Check("Show a toast", "alertToast")
    left:Check("Play a sound", "alertSound")
    left:Cycle("Alert for", "alertWho", {
        { id = "all", label = "Everyone" },
        { id = "friends", label = "Friends only" },
        { id = "pinned", label = "Pinned only" },
    })

    local right = Column(content, COLUMN_WIDTH + COLUMN_GAP)
    right:Heading("Rows")
    right:Cycle("Sort by", "sortBy", {
        { id = "level", label = "Level" },
        { id = "progress", label = "Level progress" },
        { id = "name", label = "Name" },
        { id = "recent", label = "Recent activity" },
    })
    right:Check("Show my own bar", "showSelf")
    right:Check("Show offline players", "showOffline")
    right:Check("Show max-level players", "showMaxLevel")
    right:Check("Show guildmates", "showGuild")
    right:Check("Show party members", "showParty")

    right:Heading("Visibility")
    right:Check("Hide in combat", "hideInCombat")
    right:Check("Hide in instances", "hideInInstance")
    right:Check("Hide when nobody else is listed", "hideWhenAlone")
    right:Check("Fade until hovered", "fadeUntilHover")

    right:Heading("Privacy")
    right:Check("Share my XP", "sharing", "Off stops all your XP messages. You still see other players' XP.", OnPrivacyChanged)
    right:Check("Share with friends", "shareFriends", nil, OnPrivacyChanged)
    right:Check("Share with my guild", "shareGuild",
        "A guild message reaches every guildmate running Ding. Stopping sharing with one person can't apply here, so someone you excluded who is in your guild only stops seeing your XP with this off.",
        OnPrivacyChanged)
    right:Check("Share with my party", "shareParty",
        "A party message reaches every member running Ding, including anyone you stopped sharing with.",
        OnPrivacyChanged)
    right:Check("Share my zone", "shareZone", "Adds your current zone to what you share.", OnPrivacyChanged)
    right:Action("Show hidden players again", "Lists everyone you hid with the row's right-click menu again.", function()
        ns.settings.hidden = {}
        ns.UI:ApplySettings()
    end)
    right:Action("Share with everyone again", "Clears every person you stopped sharing with.", function()
        ns.settings.excluded = {}
    end)

    content:SetHeight(-math.min(left:Bottom(), right:Bottom()) + 8)
    panel:SetScript("OnShow", function()
        for _, refresh in ipairs(refreshers) do refresh() end
    end)
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
    ns.Print("/ding: show or hide the panel")
    ns.Print("/ding options: open settings (or right-click a section header)")
    ns.Print("/ding demo: fill the panel with sample players")
    ns.Print("/ding reset: move the panel back to its starting position")
    ns.Print("/ding diag: test which message routes reach other players")
end

local function HandleSlash(input)
    local command = (input or ""):lower():match("^%s*(%S*)")
    if command == "" then
        ns.UI:Toggle()
    elseif command == "options" or command == "config" then
        Options:Open()
    elseif command == "demo" then
        ns.Print(ns.Tracker:ToggleDemo() and "Demo on. /ding demo turns it off." or "Demo off.")
    elseif command == "reset" then
        ns.UI:ResetPosition()
    elseif command == "diag" then
        ns.Comm:RunDiag()
    else
        PrintHelp()
    end
end

function Options:Start()
    SLASH_DING1 = "/ding"
    SlashCmdList.DING = HandleSlash

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local panel = BuildPanel()
        category = Settings.RegisterCanvasLayoutCategory(panel, "Ding")
        Settings.RegisterAddOnCategory(category)
    end
end
