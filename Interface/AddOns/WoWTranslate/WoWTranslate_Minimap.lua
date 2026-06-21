-- WoWTranslate_Minimap.lua
-- Minimap button for WoWTranslate (Atlas pattern)
-- Left-click toggles config panel, drag to reposition around minimap edge

local L = WoWTranslate_L

local MINIMAP_BUTTON_RADIUS = 80
local DEFAULT_POSITION = 225  -- degrees, bottom-left area
local isDragging = false

-- ============================================================================
-- UPDATE POSITION (polar -> cartesian)
-- ============================================================================
local function UpdatePosition()
    if not WoWTranslateMinimapButton then return end
    local angle = DEFAULT_POSITION
    if WoWTranslateDB and WoWTranslateDB.minimapPos then
        angle = tonumber(WoWTranslateDB.minimapPos) or DEFAULT_POSITION
    end
    local rads = math.rad(angle)
    local x = 53 - (MINIMAP_BUTTON_RADIUS * math.cos(rads))
    local y = (MINIMAP_BUTTON_RADIUS * math.sin(rads)) - 55
    WoWTranslateMinimapButton:ClearAllPoints()
    WoWTranslateMinimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", x, y)
end

-- ============================================================================
-- CREATE BUTTON (single Button on Minimap, Atlas pattern)
-- ============================================================================
local button = CreateFrame("Button", "WoWTranslateMinimapButton", Minimap)
button:SetWidth(33)
button:SetHeight(33)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:EnableMouse(true)
button:SetMovable(true)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")

-- Icon texture (scroll/note — fits "translation" theme)
local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
icon:SetWidth(20)
icon:SetHeight(20)
icon:SetPoint("CENTER", button, "CENTER", 0, 0)

-- Border texture (standard minimap button border)
local border = button:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetWidth(52)
border:SetHeight(52)
border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

-- Highlight texture
local highlight = button:CreateTexture(nil, "HIGHLIGHT")
highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
highlight:SetWidth(24)
highlight:SetHeight(24)
highlight:SetPoint("CENTER", button, "CENTER", 0, 0)
highlight:SetBlendMode("ADD")

-- ============================================================================
-- DRAG LOGIC
-- ============================================================================
button:SetScript("OnDragStart", function()
    isDragging = true
    this:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetScale()
        local cx, cy = GetCursorPosition()
        local uiScale = UIParent:GetScale()
        cx = cx / (scale * uiScale)
        cy = cy / (scale * uiScale)
        mx = mx / uiScale
        my = my / uiScale
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        if not WoWTranslateDB then WoWTranslateDB = {} end
        WoWTranslateDB.minimapPos = angle
        UpdatePosition()
    end)
end)

button:SetScript("OnDragStop", function()
    isDragging = false
    this:SetScript("OnUpdate", nil)
end)

-- ============================================================================
-- QUICK OUTGOING-LANGUAGE MENU (right-click)
-- ============================================================================
-- Sprachliste in Sync mit WoWTranslate_Config.lua. Reihenfolge = Antwort-Haeufigkeit.
local QUICK_LANGS = {
    { code = "fr", name = "French" },
    { code = "es", name = "Spanish" },
    { code = "de", name = "German" },
    { code = "pt", name = "Portuguese" },
    { code = "ru", name = "Russian" },
    { code = "zh", name = "Chinese" },
    { code = "en", name = "English" },
    { code = "ko", name = "Korean" },
    { code = "ja", name = "Japanese" },
}

local ROW_H = 15
local MENU_W = 140
local quickMenu  -- wird einmalig erzeugt

local function WT_Msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF66CCFF[WoWTranslate]|r " .. text)
end

local function RefreshQuickMenu()
    if not quickMenu then return end
    local on = WoWTranslateDB and WoWTranslateDB.outgoingEnabled
    local cur = (WoWTranslateDB and WoWTranslateDB.outgoingToLang) or "zh"
    quickMenu.toggle.text:SetText(L.OUTGOING_LABEL .. " " ..
        (on and ("|cFF00FF00" .. L.ON .. "|r") or ("|cFFFF0000" .. L.OFF .. "|r")))
    for i = 1, table.getn(quickMenu.langRows) do
        local row = quickMenu.langRows[i]
        if row.code == cur then
            row.text:SetText("|cFFFFD100> " .. row.label .. "|r")
        else
            row.text:SetText("   " .. row.label)
        end
    end
end

local function MakeRow(parent, y, onclick)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(MENU_W - 16)
    b:SetHeight(ROW_H)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", b, "LEFT", 2, 0)
    fs:SetJustifyH("LEFT")
    b.text = fs
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAllPoints(b)
    b:SetScript("OnClick", onclick)
    return b
end

local function BuildQuickMenu()
    local n = table.getn(QUICK_LANGS)
    local height = 10 + ROW_H + 6 + ROW_H + 6 + (n * ROW_H) + 8
    local m = CreateFrame("Frame", "WoWTranslateQuickMenu", UIParent)
    m:SetFrameStrata("DIALOG")
    m:SetWidth(MENU_W)
    m:SetHeight(height)
    m:EnableMouse(true)
    m:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    m:Hide()

    local title = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", m, "TOPLEFT", 8, -8)
    title:SetText(L.REPLY_LANGUAGE)

    local y = -8 - ROW_H - 4
    m.toggle = MakeRow(m, y, function()
        if not WoWTranslateDB then WoWTranslateDB = {} end
        WoWTranslateDB.outgoingEnabled = not WoWTranslateDB.outgoingEnabled
        if WoWTranslate_TempConfig then
            WoWTranslate_TempConfig.outgoingEnabled = WoWTranslateDB.outgoingEnabled
        end
        WT_Msg(L.MSG_OUTGOING_TOGGLE .. " " ..
            (WoWTranslateDB.outgoingEnabled and ("|cFF00FF00" .. L.ON .. "|r") or ("|cFFFF0000" .. L.OFF .. "|r")))
        RefreshQuickMenu()
    end)

    y = y - ROW_H - 4
    m.langRows = {}
    for i = 1, table.getn(QUICK_LANGS) do
        local lang = QUICK_LANGS[i]
        local row = MakeRow(m, y, function()
            if not WoWTranslateDB then WoWTranslateDB = {} end
            WoWTranslateDB.outgoingToLang = lang.code
            WoWTranslateDB.outgoingEnabled = true
            if WoWTranslate_TempConfig then
                WoWTranslate_TempConfig.outgoingToLang = lang.code
                WoWTranslate_TempConfig.outgoingEnabled = true
            end
            WT_Msg(L.MSG_REPLY_IN .. " |cFFFFD100" .. lang.name .. "|r |cFF00FF00" .. L.PAREN_OUTGOING_ON .. "|r")
            RefreshQuickMenu()
            m:Hide()
        end)
        row.code = lang.code
        row.label = lang.name
        m.langRows[i] = row
        y = y - ROW_H
    end

    quickMenu = m
    return m
end

function WoWTranslate_ToggleQuickMenu()
    if not quickMenu then BuildQuickMenu() end
    if quickMenu:IsShown() then
        quickMenu:Hide()
        return
    end
    quickMenu:ClearAllPoints()
    quickMenu:SetPoint("TOP", WoWTranslateMinimapButton, "BOTTOM", 0, -2)
    RefreshQuickMenu()
    quickMenu:Show()
end

-- ============================================================================
-- CLICK HANDLER
-- ============================================================================
button:SetScript("OnClick", function()
    if isDragging then return end
    if arg1 == "RightButton" then
        WoWTranslate_ToggleQuickMenu()
    elseif WoWTranslate_ToggleConfig then
        WoWTranslate_ToggleConfig()
    end
end)

-- ============================================================================
-- TOOLTIP
-- ============================================================================
button:SetScript("OnEnter", function()
    if isDragging then return end
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:AddLine("WoWTranslate")
    GameTooltip:AddLine(L.TT_LEFTCLICK, 0.8, 0.8, 0.8)
    GameTooltip:AddLine(L.TT_RIGHTCLICK, 0.8, 0.8, 0.8)
    local cur = (WoWTranslateDB and WoWTranslateDB.outgoingToLang) or "zh"
    local on = WoWTranslateDB and WoWTranslateDB.outgoingEnabled
    GameTooltip:AddLine(L.OUTGOING_LABEL .. " " .. (on and L.ON or L.OFF) .. " -> " .. cur,
        0.4, 0.8, 1.0)
    GameTooltip:Show()
end)

button:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ============================================================================
-- INITIALIZATION (called from WoWTranslate.lua after settings are loaded)
-- ============================================================================
function WoWTranslate_MinimapButton_Init()
    if not WoWTranslateDB then WoWTranslateDB = {} end
    if WoWTranslateDB.minimapPos == nil then
        WoWTranslateDB.minimapPos = DEFAULT_POSITION
    end
    UpdatePosition()
end
