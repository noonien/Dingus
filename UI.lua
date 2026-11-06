-- The panel: collapsible Party, Friends and Guild sections of XP bars.
-- Flat textures only, no assets.

local _, ns = ...

local UI = {}
ns.UI = UI

local Tracker = ns.Tracker

local FLAT = "Interface\\Buttons\\WHITE8X8"
local DEFAULT_LEFT = 36
local DEFAULT_OFFSET = 220
local PADDING = 3
local CLICK_SLOP = 8 -- cursor travel, in screen pixels, that still counts as a click
local SECTION_HEIGHT = 16
local SECTION_GAP = 2
local SECTION_SPACING = 6
local SECTION_FONT_SIZE = 10
local SECTION_LINE_ALPHA = 0.12
local MORE_HEIGHT = 16
local FADED_ALPHA = 0.25
-- Bars stay quiet: colours lean towards grey, and the fill is a deep tone of them
-- so white text stays readable. Quest and rested XP sit on nothing, so they need a
-- brighter tone than the fill to be seen through their transparency.
local MUTE_AMOUNT = 0.5
local SEGMENT_TOP = 0.30
local SEGMENT_BOTTOM = 0.22
local OVERLAY_TOP = 0.65
local OVERLAY_BOTTOM = 0.5
local OVERLAY_ALPHA = 0.65
local OFFLINE_OVERLAY_ALPHA = 0.3
local ICON_BRIGHTNESS = 0.7
local TITLE_BRIGHTNESS = 0.8
local CLASS_ICONS = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local ANIM_SECONDS = 0.25
local TOAST_HOLD = 4
local TOAST_FADE = 0.3
local UPDATE_SECONDS = 15

local COLOR = {
    frame = { 14 / 255, 16 / 255, 20 / 255 },
    hover = { 1, 1, 1, 0.08 },
    edge = { 1, 1, 1, 0.2 },
    offline = { 141 / 255, 147 / 255, 156 / 255 },
    muted = { 201 / 255, 206 / 255, 214 / 255 },
    rested = { 0.30, 0.55, 1 },
    quest = { 0.95, 0.75, 0.25 },
    party = { 0.67, 0.67, 1 },
    friends = { 0.35, 0.75, 1 },
    guild = { 0.35, 0.9, 0.45 },
}

-- Gold isn't offered: it would read as the finished-quest segment.
ns.BAR_COLORS = {
    { id = "class", label = "Class" },
    { id = "sky", label = "Sky", rgb = { 127 / 255, 178 / 255, 229 / 255 } },
    { id = "mint", label = "Mint", rgb = { 127 / 255, 224 / 255, 200 / 255 } },
    { id = "violet", label = "Violet", rgb = { 170 / 255, 150 / 255, 240 / 255 } },
    { id = "rose", label = "Rose", rgb = { 240 / 255, 150 / 255, 170 / 255 } },
}

ns.FONTS = {
    { id = "default", label = "Standard", global = "STANDARD_TEXT_FONT" },
    { id = "names", label = "Unit names", global = "UNIT_NAME_FONT" },
    { id = "damage", label = "Damage", global = "DAMAGE_TEXT_FONT" },
}

local frame
local sections = {}
local rows = {}
local refreshPending = false
local toast
local toastQueue = {}

local function FontPath()
    local id = ns.settings.font
    for _, font in ipairs(ns.FONTS) do
        if font.id == id and _G[font.global] then return _G[font.global] end
    end
    return STANDARD_TEXT_FONT
end

local function StyleText(text, size, flags)
    text:SetFont(FontPath(), size or ns.settings.fontSize, flags or "")
    text:SetShadowColor(0, 0, 0, 0.9)
    text:SetShadowOffset(1, -1)
end

local function NewText(parent, justify)
    local text = parent:CreateFontString(nil, "OVERLAY")
    StyleText(text)
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    text:SetTextColor(1, 1, 1)
    return text
end

local function NewFlat(parent, layer, sublevel)
    local texture = parent:CreateTexture(nil, layer, nil, sublevel)
    texture:SetTexture(FLAT)
    return texture
end

--- A colour moved part of the way to the grey of the same brightness.
local function Mute(r, g, b)
    local grey = r * 0.3 + g * 0.59 + b * 0.11
    return r + (grey - r) * MUTE_AMOUNT, g + (grey - g) * MUTE_AMOUNT, b + (grey - b) * MUTE_AMOUNT
end

--- A muted tone, lit slightly from above.
local function PaintSegment(segment, r, g, b, top, bottom, a)
    r, g, b = Mute(r, g, b)
    segment:SetGradient("VERTICAL",
        CreateColor(r * bottom, g * bottom, b * bottom, a),
        CreateColor(r * top, g * top, b * top, a))
end

local function ClassColor(class)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    return 0.8, 0.8, 0.8
end

--- Bar colour for a row: grey when offline, otherwise the chosen colour.
local function BarColor(entry)
    if not entry.online then return unpack(COLOR.offline) end
    for _, option in ipairs(ns.BAR_COLORS) do
        if option.id == ns.settings.barColor and option.rgb then return unpack(option.rgb) end
    end
    return ClassColor(entry.peer.class)
end

local function IsMaxLevel(peer)
    local maximum = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion() or GetMaxPlayerLevel()
    return peer.level >= maximum or (peer.xpMax or 0) <= 0
end

--------------------------------------------------------------------------------
-- Tooltip
--------------------------------------------------------------------------------

local function ClassLabel(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class or ""
end

local function Compare(peer, mine)
    if not mine or peer == mine then return nil end
    local difference = peer.level - mine.level
    if difference > 0 then
        return ("%d |4level:levels; ahead of you"):format(difference)
    elseif difference < 0 then
        return ("%d |4level:levels; behind you"):format(-difference)
    end
    return nil
end

local function ShowTooltip(row)
    local entry = row.entry
    if not entry then return end
    local peer = entry.peer
    local r, g, b = ClassColor(peer.class)
    local number, duration = Tracker.FormatNumber, Tracker.FormatDuration
    local muted = COLOR.muted

    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local centerX = frame:GetCenter()
    if centerX and centerX > UIParent:GetWidth() / 2 then
        GameTooltip:SetPoint("TOPRIGHT", row, "TOPLEFT", -PADDING * 2, 0)
    else
        GameTooltip:SetPoint("TOPLEFT", row, "TOPRIGHT", PADDING * 2, 0)
    end

    GameTooltip:AddLine(peer.name, r, g, b)
    local subtitle = ("Level %d %s"):format(peer.level, ClassLabel(peer.class))
    if not entry.online then subtitle = subtitle .. ", offline" end
    GameTooltip:AddLine(subtitle, muted[1], muted[2], muted[3])
    local compare = Compare(peer, UI.lastList and UI.lastList.self.peer)
    if compare then GameTooltip:AddLine(compare, muted[1], muted[2], muted[3]) end
    GameTooltip:AddLine(" ")

    local function Field(label, value, color)
        color = color or muted
        GameTooltip:AddDoubleLine(label, value, color[1], color[2], color[3], 1, 1, 1)
    end

    if not IsMaxLevel(peer) then
        Field("XP", number(peer.xp) .. " / " .. number(peer.xpMax))
        -- These two are coloured to match their segments on the bar.
        local quest = peer.questXP or 0
        if quest > 0 then
            Field("Completed quests", ("%s (%d%%)"):format(number(quest), quest / peer.xpMax * 100), COLOR.quest)
        end
        local rested = peer.rested or 0
        if rested > 0 then
            Field("Rested", ("%s (%d%%)"):format(number(rested), rested / peer.xpMax * 100), COLOR.rested)
        else
            Field("Rested", "None", COLOR.rested)
        end
        local perHour = entry.online and Tracker.Rate.Get(entry.runtime.rate, GetTime()) or nil
        if perHour then
            Field("XP/hour", number(perHour))
            Field("To level", duration(Tracker.Rate.TimeToLevel(perHour, peer.xp, peer.xpMax)))
        else
            Field("XP/hour", entry.online and "No recent XP" or "Not playing")
        end
    end

    if peer.zone then
        Field(entry.online and "Zone" or "Last zone", peer.zone)
    elseif not entry.isSelf then
        Field("Zone", "Not shared")
    end
    if not entry.isSelf then
        Field("Updated", Tracker.FormatAgo(time() - (peer.seen or 0)) .. " ago")
    end

    if entry.alts then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Other characters", muted[1], muted[2], muted[3])
        for _, alt in ipairs(entry.alts) do
            local altR, altG, altB = ClassColor(alt.class)
            GameTooltip:AddDoubleLine(alt.name, ("Level %d"):format(alt.level), altR, altG, altB, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Row actions
--------------------------------------------------------------------------------

local function OpenWhisper(peer)
    local accountName = ns.Roster:AccountName(peer.account)
    -- An explicit chat frame avoids the temporary-window path that EllesmereUI
    -- found taints chat.
    if accountName then
        local sendBN = (ChatFrameUtil and ChatFrameUtil.SendBNetTell) or ChatFrame_SendBNetTell
        if sendBN then sendBN(accountName, DEFAULT_CHAT_FRAME) return end
    end
    local sendTell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
    if sendTell then sendTell(peer.name, DEFAULT_CHAT_FRAME) end
end

local function SetExcluded(peer, excluded)
    local value = excluded or nil
    ns.settings.excluded[peer.key] = value
    if peer.account then ns.settings.excluded["account:" .. peer.account] = value end
end

local function IsExcluded(peer)
    return ns.settings.excluded[peer.key] ~= nil
end

local function OpenMenu(row)
    local entry = row.entry
    if not entry or entry.isSelf or not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local peer = entry.peer
    local s = ns.settings
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(peer.name)
        local online = entry.online and true or false
        root:CreateButton("Whisper", function() OpenWhisper(peer) end):SetEnabled(online)
        root:CreateButton("Invite", function()
            if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(peer.name) end
        end):SetEnabled(online)
        root:CreateButton(s.pinned[peer.key] and "Unpin" or "Pin to top", function()
            s.pinned[peer.key] = not s.pinned[peer.key] or nil
            UI:Refresh()
        end)
        root:CreateButton("Hide", function()
            s.hidden[peer.key] = true
            UI:Refresh()
        end)
        root:CreateButton(IsExcluded(peer) and "Share my XP with them" or "Stop sharing my XP with them", function()
            SetExcluded(peer, not IsExcluded(peer))
        end)
    end)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- Places a segment on the bar from `start` for `share`, both fractions of its width.
local function PlaceSegment(row, segment, start, share)
    if share <= 0 then
        segment:Hide()
        return
    end
    segment:Show()
    segment:ClearAllPoints()
    segment:SetPoint("TOPLEFT", row.track, "TOPLEFT", row.barWidth * start, 0)
    segment:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT", row.barWidth * start, 0)
    segment:SetWidth(math.max(1, row.barWidth * share))
end

--- Current XP, then finished quests, then rested, each picking up where the last ended.
local function SetBar(row, fraction)
    row.barFraction = fraction
    PlaceSegment(row, row.fill, 0, fraction)

    local questShare = math.min(row.questFraction or 0, 1 - fraction)
    PlaceSegment(row, row.quest, fraction, questShare)
    local restShare = math.min(row.restFraction or 0, 1 - fraction - questShare)
    PlaceSegment(row, row.rest, fraction + questShare, restShare)

    if fraction > 0 and fraction < 1 then
        row.edge:Show()
        row.edge:ClearAllPoints()
        row.edge:SetPoint("TOPLEFT", row.track, "TOPLEFT", row.barWidth * fraction - 1, 0)
        row.edge:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT", row.barWidth * fraction - 1, 0)
    else
        row.edge:Hide()
    end
end

local function AnimateRow(row, elapsed)
    local remaining = row.target - row.barFraction
    local step = elapsed / ANIM_SECONDS * (row.animDistance or 0)
    if math.abs(remaining) <= step or step <= 0 then
        SetBar(row, row.target)
        row:SetScript("OnUpdate", nil)
    else
        SetBar(row, row.barFraction + (remaining > 0 and step or -step))
    end
end

local function SavePosition()
    ns.settings.anchor = { left = frame:GetLeft(), top = frame:GetTop(), bottom = frame:GetBottom() }
    UI:RestorePosition()
end

local pressX, pressY = 0, 0
local moving = false

local function CursorTravel()
    local x, y = GetCursorPosition()
    return math.max(math.abs(x - pressX), math.abs(y - pressY))
end

--- Sections and rows both drag the panel, since it has no title bar. Whether a
--- press was a click or a drag depends only on how far the cursor went, because
--- the game can report a drag for a tiny movement and may not send a click after one.
local function EnableClickAndDrag(button, onClick)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnMouseDown", function()
        pressX, pressY = GetCursorPosition()
    end)
    button:SetScript("OnMouseUp", function(self, mouse)
        if CursorTravel() <= CLICK_SLOP and self:IsMouseOver() then onClick(self, mouse) end
    end)
    button:SetScript("OnDragStart", function()
        if ns.settings.locked then return end
        moving = true
        frame:StartMoving()
    end)
    button:SetScript("OnDragStop", function()
        if not moving then return end
        moving = false
        frame:StopMovingOrSizing()
        if CursorTravel() <= CLICK_SLOP then
            UI:RestorePosition() -- a click that shifted slightly: put the panel back
        else
            SavePosition()
        end
    end)
end

local function NewRow()
    local row = CreateFrame("Button", nil, frame)
    EnableClickAndDrag(row, function(self, button)
        if button == "RightButton" then OpenMenu(self) end
    end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("TOPLEFT")

    -- Nothing is drawn behind the bar: this only marks where its segments start.
    row.track = row:CreateTexture(nil, "BACKGROUND")

    row.rest = NewFlat(row, "BORDER", 0)
    row.quest = NewFlat(row, "BORDER", 1)
    row.fill = NewFlat(row, "BORDER", 2)

    row.hover = NewFlat(row, "ARTWORK", 0)
    row.hover:SetAllPoints()
    row.hover:SetVertexColor(unpack(COLOR.hover))
    row.hover:Hide()

    row.edge = NewFlat(row, "ARTWORK", 1)
    row.edge:SetVertexColor(unpack(COLOR.edge))
    row.edge:SetWidth(1)

    row.pin = NewFlat(row, "ARTWORK", 2)
    row.pin:SetVertexColor(1, 1, 1)
    row.pin:SetSize(4, 4)
    row.pin:SetPoint("TOPLEFT", row.icon, "TOPLEFT", 1, -1)

    row.percent = NewText(row, "RIGHT")
    row.percent:SetPoint("RIGHT", row.track, "RIGHT", -5, 0)
    row.extra = NewText(row, "RIGHT")
    row.extra:SetPoint("RIGHT", row.percent, "LEFT", -6, 0)
    row.extra:SetTextColor(unpack(COLOR.muted))
    row.level = NewText(row, "CENTER")
    row.level:SetPoint("LEFT", row.track, "LEFT", 3, 0)
    row.name = NewText(row, "LEFT")
    row.name:SetPoint("LEFT", row.level, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.extra, "LEFT", -6, 0)

    row:SetScript("OnEnter", function(self)
        self.hover:Show()
        ShowTooltip(self)
    end)
    row:SetScript("OnLeave", function(self)
        self.hover:Hide()
        GameTooltip:Hide()
    end)
    return row
end

local function BarText(row, peer)
    local mode = ns.settings.barText
    local showLevel = mode == "full" or mode == "level"
    row.level:SetWidth(showLevel and 18 or 1)
    row.level:SetText(showLevel and peer.level or "")

    local percent = ""
    if mode == "full" or mode == "percent" then
        if IsMaxLevel(peer) then
            percent = "Max"
        elseif mode == "percent" then
            percent = ("%d%%"):format(peer.xp / peer.xpMax * 100)
        else
            percent = ("%s/%s (%d%%)"):format(Tracker.FormatShort(peer.xp), Tracker.FormatShort(peer.xpMax),
                peer.xp / peer.xpMax * 100)
        end
    end
    row.percent:SetText(percent)
end

local function PaintIcon(row, entry)
    local icon, class = row.icon, entry.peer.class
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        icon:SetTexture(CLASS_ICONS)
        icon:SetTexCoord(unpack(coords))
        icon:SetVertexColor(ICON_BRIGHTNESS, ICON_BRIGHTNESS, ICON_BRIGHTNESS)
    else
        -- A class with no icon art still gets its colour.
        icon:SetTexture(FLAT)
        icon:SetTexCoord(0, 1, 0, 1)
        local r, g, b = Mute(ClassColor(class))
        icon:SetVertexColor(r * ICON_BRIGHTNESS, g * ICON_BRIGHTNESS, b * ICON_BRIGHTNESS)
    end
    icon:SetDesaturated(not entry.online)
end

local function UpdateRow(row, entry, y, width)
    local s = ns.settings
    local peer = entry.peer
    row.entry = entry
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
    row:SetSize(width, s.barHeight)
    -- A square icon, then the bar: the row's height sets the icon's size.
    row.icon:SetSize(s.barHeight, s.barHeight)
    row.track:ClearAllPoints()
    row.track:SetPoint("TOPLEFT", row, "TOPLEFT", s.barHeight + 1, 0)
    row.track:SetPoint("BOTTOMRIGHT")
    row.barWidth = width - s.barHeight - 1
    PaintIcon(row, entry)

    local r, g, b = BarColor(entry)
    PaintSegment(row.fill, r, g, b, SEGMENT_TOP, SEGMENT_BOTTOM, 1)
    local overlayAlpha = entry.online and OVERLAY_ALPHA or OFFLINE_OVERLAY_ALPHA
    PaintSegment(row.quest, COLOR.quest[1], COLOR.quest[2], COLOR.quest[3], OVERLAY_TOP, OVERLAY_BOTTOM, overlayAlpha)
    PaintSegment(row.rest, COLOR.rested[1], COLOR.rested[2], COLOR.rested[3], OVERLAY_TOP, OVERLAY_BOTTOM, overlayAlpha)
    row.pin:SetShown(s.pinned[peer.key] and true or false)

    for _, text in ipairs({ row.name, row.level, row.percent, row.extra }) do StyleText(text) end
    row.name:SetText(entry.isSelf and "You" or peer.name)
    if entry.online then
        row.name:SetTextColor(1, 1, 1)
    else
        row.name:SetTextColor(unpack(COLOR.muted))
    end
    BarText(row, peer)
    row.extra:SetText(entry.online and "" or Tracker.FormatAgo(time() - (peer.seen or 0)))

    local maxed = IsMaxLevel(peer)
    local fraction = maxed and 1 or math.min(1, peer.xp / peer.xpMax)
    row.questFraction = maxed and 0 or (peer.questXP or 0) / peer.xpMax
    row.restFraction = maxed and 0 or (peer.rested or 0) / peer.xpMax

    if row.entryKey ~= peer.key or not row.barFraction or fraction < row.barFraction then
        -- A different person or a new level: jump rather than slide backwards.
        row.entryKey = peer.key
        row:SetScript("OnUpdate", nil)
        row.target = fraction
        SetBar(row, fraction)
    elseif fraction ~= row.target then
        row.target = fraction
        row.animDistance = math.abs(fraction - row.barFraction)
        row:SetScript("OnUpdate", AnimateRow)
    else
        SetBar(row, row.barFraction)
    end
    row:Show()
end

--------------------------------------------------------------------------------
-- Sections
--------------------------------------------------------------------------------

local function DrawChevron(section, collapsed)
    local a, b = section.chevronA, section.chevronB
    local x = 6
    if collapsed then
        a:SetStartPoint("LEFT", section.button, x - 2, 3)
        a:SetEndPoint("LEFT", section.button, x + 1, 0)
        b:SetStartPoint("LEFT", section.button, x + 1, 0)
        b:SetEndPoint("LEFT", section.button, x - 2, -3)
    else
        a:SetStartPoint("LEFT", section.button, x - 3, 1.5)
        a:SetEndPoint("LEFT", section.button, x, -1.5)
        b:SetStartPoint("LEFT", section.button, x, -1.5)
        b:SetEndPoint("LEFT", section.button, x + 3, 1.5)
    end
end

local function NewSection(id, label)
    local section = { id = id }
    local button = CreateFrame("Button", nil, frame)
    section.button = button
    button:SetHeight(SECTION_HEIGHT)
    EnableClickAndDrag(button, function(_, mouse)
        if mouse == "RightButton" then
            ns.Options:Open()
        else
            UI:ToggleSection(id)
        end
    end)

    local accent = COLOR[id]
    local highlight = NewFlat(button, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetVertexColor(unpack(COLOR.hover))

    section.title = NewText(button, "LEFT")
    section.title:SetPoint("LEFT", button, "LEFT", 14, 0)
    section.title:SetText(label)
    local titleR, titleG, titleB = Mute(accent[1], accent[2], accent[3])
    section.title:SetTextColor(titleR * TITLE_BRIGHTNESS, titleG * TITLE_BRIGHTNESS, titleB * TITLE_BRIGHTNESS)
    section.count = NewText(button, "RIGHT")
    section.count:SetPoint("RIGHT", button, "RIGHT", -2, 0)
    section.count:SetTextColor(unpack(COLOR.muted))

    local line = NewFlat(button, "ARTWORK")
    line:SetVertexColor(1, 1, 1, SECTION_LINE_ALPHA)
    line:SetHeight(1)
    line:SetPoint("LEFT", section.title, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", section.count, "LEFT", -6, 0)

    section.chevronA = button:CreateLine(nil, "ARTWORK")
    section.chevronB = button:CreateLine(nil, "ARTWORK")
    for _, line in ipairs({ section.chevronA, section.chevronB }) do
        line:SetThickness(1.5)
        line:SetColorTexture(unpack(COLOR.muted))
    end

    section.more = NewText(frame, "LEFT")
    section.more:SetTextColor(unpack(COLOR.muted))

    return section
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local function ShouldShow(list)
    local s = ns.settings
    if not s.shown then return false end
    if s.hideInCombat and InCombatLockdown() then return false end
    if s.hideInInstance and IsInInstance() then return false end
    -- Empty sections don't show, so with nothing listed there's nothing to draw.
    if #list.party + #list.friends + #list.guild == 0 and (s.hideWhenAlone or not s.showSelf) then return false end
    return true
end

local function Render()
    local s = ns.settings
    local list = Tracker:BuildList()
    UI.lastList = list

    frame:SetShown(ShouldShow(list))
    frame:SetWidth(s.width)
    frame.bg:SetVertexColor(COLOR.frame[1], COLOR.frame[2], COLOR.frame[3], s.opacity)

    local width = s.width - PADDING * 2
    local y = -PADDING
    local gap = 0 -- space after the last item, which the panel's padding replaces
    local used = 0
    local budget = s.maxRows

    local function AddRow(entry)
        used = used + 1
        rows[used] = rows[used] or NewRow()
        UpdateRow(rows[used], entry, y, width)
        gap = s.spacing
        y = y - s.barHeight - gap
    end

    local function AddSection(section, entries, online)
        local visible = #entries > 0
        section.button:SetShown(visible)
        section.more:Hide()
        if not visible then return end

        if y < -PADDING then y = y - SECTION_SPACING end
        section.button:ClearAllPoints()
        section.button:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, y)
        section.button:SetWidth(width)
        StyleText(section.title, SECTION_FONT_SIZE)
        StyleText(section.count, SECTION_FONT_SIZE)
        section.count:SetText(online and ("%d online"):format(online) or "")
        local collapsed = s.collapsedSections[section.id] and true or false
        DrawChevron(section, collapsed)
        gap = SECTION_GAP
        y = y - SECTION_HEIGHT - gap
        if collapsed then return end

        local hidden = 0
        for _, entry in ipairs(entries) do
            if budget > 0 then
                AddRow(entry)
                budget = budget - 1
            else
                hidden = hidden + 1
            end
        end
        if hidden > 0 then
            section.more:ClearAllPoints()
            section.more:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING + 2, y)
            StyleText(section.more, 11)
            section.more:SetText(("+%d more"):format(hidden))
            section.more:Show()
            gap = 0
            y = y - MORE_HEIGHT
        end
    end

    if s.showSelf then AddRow(list.self) end
    AddSection(sections.friends, list.friends, list.friendsOnline)
    -- Everyone in a party is online, so a count there says nothing.
    AddSection(sections.party, list.party)
    AddSection(sections.guild, list.guild, list.guildOnline)

    for i = used + 1, #rows do
        rows[i]:Hide()
        rows[i].entry = nil
    end
    frame:SetHeight(-y - gap + PADDING)
end

--- Redraws soon. A burst of messages costs one redraw.
function UI:Refresh()
    if refreshPending or not frame then return end
    refreshPending = true
    C_Timer.After(0.1, function()
        refreshPending = false
        Render()
    end)
end

--- Folds or unfolds a section. The top edge holds even when growing upward, so
--- the header under the mouse stays put; grow direction is for players coming and going.
function UI:ToggleSection(id)
    local s = ns.settings
    local top = frame:GetTop()
    s.collapsedSections[id] = not s.collapsedSections[id] or nil
    Render()
    if s.growUp and top then
        s.anchor = { left = frame:GetLeft(), top = top, bottom = top - frame:GetHeight() }
        self:RestorePosition()
    end
end

--- Reapplies settings that affect the frame's anchor as well as its contents.
function UI:ApplySettings()
    if not frame then return end
    -- A panel that was never moved stays unsaved, so it follows the default position.
    if ns.settings.anchor then self:HoldPosition() end
    self:RestorePosition()
    Render()
end

--- Saves the panel's edges. The edge not holding the panel goes stale as its
--- height changes, so both are read. Switching grow direction after this leaves
--- the panel where it is.
function UI:HoldPosition()
    if frame and frame:GetTop() then
        ns.settings.anchor = { left = frame:GetLeft(), top = frame:GetTop(), bottom = frame:GetBottom() }
    end
end

function UI:RestorePosition()
    local s = ns.settings
    local anchor = s.anchor
    frame:ClearAllPoints()
    if anchor then
        if s.growUp then
            frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", anchor.left, anchor.bottom)
        else
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", anchor.left, anchor.top)
        end
    elseif s.growUp then
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", DEFAULT_LEFT, DEFAULT_OFFSET)
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", DEFAULT_LEFT, -DEFAULT_OFFSET)
    end
end

function UI:ResetPosition()
    ns.settings.anchor = nil
    self:RestorePosition()
    Render()
end

--------------------------------------------------------------------------------
-- Level-up toast
--------------------------------------------------------------------------------

local function ShowNextToast()
    local peer = table.remove(toastQueue, 1)
    if not peer then return end
    local r, g, b = ClassColor(peer.class)
    toast.chip:SetVertexColor(r, g, b)
    StyleText(toast.level, 13)
    StyleText(toast.text, 13)
    toast.level:SetText(peer.level)
    toast.text:SetText(("%s reached level %d"):format(peer.name, peer.level))
    toast:SetWidth(toast.text:GetStringWidth() + 56)
    toast:Show()
    toast.anim:Stop()
    toast.anim:Play()
end

local function BuildToast()
    toast = CreateFrame("Frame", nil, UIParent)
    toast:SetFrameStrata("HIGH")
    toast:SetHeight(36)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -140)
    toast:Hide()

    local bg = NewFlat(toast, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetVertexColor(COLOR.frame[1], COLOR.frame[2], COLOR.frame[3], 0.92)

    toast.chip = NewFlat(toast, "BORDER")
    toast.chip:SetSize(28, 22)
    toast.chip:SetPoint("LEFT", toast, "LEFT", 8, 0)

    toast.level = NewText(toast, "CENTER")
    toast.level:SetPoint("CENTER", toast.chip, "CENTER")
    toast.level:SetTextColor(0.06, 0.07, 0.09)
    toast.level:SetShadowOffset(0, 0)

    toast.text = NewText(toast, "LEFT")
    toast.text:SetPoint("LEFT", toast.chip, "RIGHT", 10, 0)

    local anim = toast:CreateAnimationGroup()
    local fadeIn = anim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(TOAST_FADE)
    fadeIn:SetOrder(1)
    local fadeOut = anim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetStartDelay(TOAST_HOLD)
    fadeOut:SetDuration(TOAST_FADE)
    fadeOut:SetOrder(2)
    anim:SetScript("OnFinished", function()
        toast:Hide()
        ShowNextToast()
    end)
    toast.anim = anim
end

function UI:ShowLevelUp(peer)
    local s = ns.settings
    if s.alertWho == "pinned" and not s.pinned[peer.key] then return end
    if s.alertWho == "friends" and not ns.Roster:IsFriend(peer) and not Tracker:IsDemo() then return end
    if s.alertSound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then PlaySound(SOUNDKIT.TELL_MESSAGE) end
    if not s.alertToast or not toast then return end
    table.insert(toastQueue, { name = peer.name, class = peer.class, level = peer.level })
    if not toast:IsShown() then ShowNextToast() end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function BuildFrame()
    frame = CreateFrame("Frame", "DingusFrame", UIParent)
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)

    frame.bg = NewFlat(frame, "BACKGROUND", -8)
    frame.bg:SetAllPoints()

    sections.party = NewSection("party", "PARTY")
    sections.friends = NewSection("friends", "FRIENDS")
    sections.guild = NewSection("guild", "GUILD")

    -- The hover fade has to check the mouse itself: rows take the panel's mouse events.
    local fadeClock = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        fadeClock = fadeClock + elapsed
        if fadeClock < 0.15 then return end
        fadeClock = 0
        local alpha = 1
        if ns.settings.fadeUntilHover and not MouseIsOver(self) then alpha = FADED_ALPHA end
        if self:GetAlpha() ~= alpha then self:SetAlpha(alpha) end
    end)
end

function UI:Start()
    BuildFrame()
    BuildToast()
    self:ApplySettings()
    for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
        ns.On(event, function() UI:Refresh() end)
    end
    -- Keeps "3h" and the online state current when no messages arrive.
    C_Timer.NewTicker(UPDATE_SECONDS, function() UI:Refresh() end)
end