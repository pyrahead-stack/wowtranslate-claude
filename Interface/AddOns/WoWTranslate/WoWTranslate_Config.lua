-- WoWTranslate_Config.lua
-- Configuration UI panel for WoWTranslate
-- v0.12: Added player name protection toggle, FetchCredits on open

-- ============================================================================
-- LANGUAGES
-- ============================================================================
local LANGUAGES = {
    { code = "auto", name = "Auto (any)" },
    { code = "zh", name = "Chinese" },
    { code = "en", name = "English" },
    { code = "ko", name = "Korean" },
    { code = "ja", name = "Japanese" },
    { code = "ru", name = "Russian" },
    { code = "de", name = "German" },
    { code = "fr", name = "French" },
    { code = "es", name = "Spanish" },
    { code = "pt", name = "Portuguese" },
}

-- Languages offered in the "I understand (don't translate)" grid. Label = the
-- short tag shown to the user; code = the ISO code sent to the proxy.
local UNDERSTAND_LANGS = {
    { code = "en", label = "EN" }, { code = "de", label = "DE" },
    { code = "fr", label = "FR" }, { code = "es", label = "ES" },
    { code = "it", label = "IT" }, { code = "pt", label = "PT" },
    { code = "ru", label = "RU" }, { code = "zh", label = "CN" },
    { code = "ja", label = "JP" }, { code = "ko", label = "KR" },
}

local function GetLanguageIndex(code)
    for i = 1, table.getn(LANGUAGES) do
        if LANGUAGES[i].code == code then
            return i
        end
    end
    return 1
end

local function GetLanguageName(code)
    for i = 1, table.getn(LANGUAGES) do
        if LANGUAGES[i].code == code then
            return LANGUAGES[i].name
        end
    end
    return code
end

-- ============================================================================
-- TEMP CONFIG
-- ============================================================================
WoWTranslate_TempConfig = {}

local function LoadTempConfig()
    WoWTranslate_TempConfig = {}
    if not WoWTranslateDB then return end
    for k, v in pairs(WoWTranslateDB) do
        if type(v) == "table" then
            WoWTranslate_TempConfig[k] = {}
            for k2, v2 in pairs(v) do
                WoWTranslate_TempConfig[k][k2] = v2
            end
        else
            WoWTranslate_TempConfig[k] = v
        end
    end
end

local function SaveTempConfig()
    if not WoWTranslate_TempConfig then return end
    for k, v in pairs(WoWTranslate_TempConfig) do
        if type(v) == "table" then
            if not WoWTranslateDB[k] then
                WoWTranslateDB[k] = {}
            end
            for k2, v2 in pairs(v) do
                WoWTranslateDB[k][k2] = v2
            end
        else
            WoWTranslateDB[k] = v
        end
    end
end

-- ============================================================================
-- HELPER: Mask API Key (show first 4 chars + asterisks)
-- ============================================================================
local function MaskApiKey(key)
    if not key or key == "" then
        return "(not set)"
    end
    if string.len(key) <= 4 then
        return key
    end
    local visible = string.sub(key, 1, 4)
    local hidden = string.rep("*", string.len(key) - 4)
    return visible .. hidden
end

-- ============================================================================
-- CREATE MAIN FRAME (bigger size to accommodate credits)
-- ============================================================================
local configFrame = CreateFrame("Frame", "WoWTranslateConfigFrame", UIParent)
configFrame:Hide()
configFrame:SetWidth(420)
configFrame:SetHeight(800)  -- single page: sections + "understand" grid
configFrame:SetPoint("CENTER", 0, 0)
configFrame:SetMovable(true)
configFrame:EnableMouse(true)
configFrame:SetClampedToScreen(true)
configFrame:SetFrameStrata("DIALOG")

configFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
configFrame:SetBackdropColor(0, 0, 0, 1)

configFrame:SetScript("OnMouseDown", function()
    this:StartMoving()
end)

configFrame:SetScript("OnMouseUp", function()
    this:StopMovingOrSizing()
end)

-- Title
local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOP", configFrame, "TOP", 0, -20)
title:SetText("WoWTranslate Configuration")

-- Close button
local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function()
    configFrame:Hide()
end)

-- ESC to close
tinsert(UISpecialFrames, "WoWTranslateConfigFrame")

-- ============================================================================
-- UI ELEMENTS STORAGE
-- ============================================================================
configFrame.elements = {}

-- ============================================================================
-- HELPER: Create Section Header
-- ============================================================================
local function CreateHeader(text, yPos)
    local header = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, yPos)
    header:SetText(text)
    header:SetTextColor(1, 0.82, 0)

    -- Thin gold divider under the header for clear section separation.
    local line = configFrame:CreateTexture(nil, "ARTWORK")
    line:SetTexture(1, 0.82, 0, 0.30)  -- vanilla: rgba = solid color
    line:SetHeight(1)
    line:SetWidth(370)
    line:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, yPos - 22)
    return header
end

-- ============================================================================
-- HELPER: Create Checkbox at specific position
-- ============================================================================
local function CreateCheckbox(label, xPos, yPos, configKey, subKey, parent)
    local p = parent or configFrame
    -- Create a wrapper frame like the language selector does
    local wrapper = CreateFrame("Frame", nil, p)
    wrapper:SetPoint("TOPLEFT", p, "TOPLEFT", xPos, yPos)
    wrapper:SetWidth(200)
    wrapper:SetHeight(24)

    -- Store config on wrapper (same pattern as language selector)
    wrapper.configKey = configKey
    wrapper.subKey = subKey

    local cb = CreateFrame("CheckButton", nil, wrapper, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 0, 0)

    local text = wrapper:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)

    cb:SetScript("OnClick", function()
        -- Use GetParent() like language selector does
        local parent = this:GetParent()
        local key = parent.configKey
        local sub = parent.subKey

        -- GetChecked() returns 1 or nil in WoW 1.12
        local isChecked = this:GetChecked()
        local enabled = (isChecked and true) or false

        -- Use the global toggle functions for immediate effect
        if key == "outgoingEnabled" then
            WoWTranslate_SetOutgoingEnabled(enabled)
            WoWTranslate_TempConfig.outgoingEnabled = enabled
        elseif key == "enabled" then
            WoWTranslate_SetIncomingEnabled(enabled)
            WoWTranslate_TempConfig.enabled = enabled
        elseif key == "outgoingChannels" and sub then
            WoWTranslate_SetChannelEnabled(sub, enabled)
            if not WoWTranslate_TempConfig.outgoingChannels then
                WoWTranslate_TempConfig.outgoingChannels = {}
            end
            WoWTranslate_TempConfig.outgoingChannels[sub] = enabled
        elseif key == "incomingChannels" and sub then
            WoWTranslate_SetIncomingChannelEnabled(sub, enabled)
            if not WoWTranslate_TempConfig.incomingChannels then
                WoWTranslate_TempConfig.incomingChannels = {}
            end
            WoWTranslate_TempConfig.incomingChannels[sub] = enabled
        else
            -- Fallback for any other settings
            if sub then
                if not WoWTranslate_TempConfig[key] then
                    WoWTranslate_TempConfig[key] = {}
                end
                WoWTranslate_TempConfig[key][sub] = enabled
                if not WoWTranslateDB[key] then
                    WoWTranslateDB[key] = {}
                end
                WoWTranslateDB[key][sub] = enabled
            else
                WoWTranslate_TempConfig[key] = enabled
                WoWTranslateDB[key] = enabled
            end
        end
    end)

    -- Return the checkbox (not wrapper) so SetChecked works
    cb.wrapper = wrapper
    return cb
end

-- ============================================================================
-- HELPER: Create Language Selector
-- ============================================================================
-- allowAuto: true for source ("From") selectors so "Auto (any)" can be chosen.
-- Target ("To") selectors set it false -- you must translate INTO a concrete language.
local function CreateLangSelector(label, xPos, yPos, configKey, parent, allowAuto)
    local p = parent or configFrame
    local frame = CreateFrame("Frame", nil, p)
    frame:SetPoint("TOPLEFT", p, "TOPLEFT", xPos, yPos)
    frame:SetWidth(170)
    frame:SetHeight(50)
    frame.minIndex = allowAuto and 1 or 2  -- index 1 == "auto"; skip it for targets

    local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)

    local leftBtn = CreateFrame("Button", nil, frame)
    leftBtn:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -6)
    leftBtn:SetWidth(24)
    leftBtn:SetHeight(24)
    leftBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
    leftBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
    leftBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    local display = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    display:SetPoint("LEFT", leftBtn, "RIGHT", 10, 0)
    display:SetWidth(85)
    display:SetJustifyH("CENTER")
    display:SetText("Language")

    local rightBtn = CreateFrame("Button", nil, frame)
    rightBtn:SetPoint("LEFT", display, "RIGHT", 10, 0)
    rightBtn:SetWidth(24)
    rightBtn:SetHeight(24)
    rightBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    rightBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    rightBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    frame.display = display
    frame.configKey = configKey

    leftBtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        local code = WoWTranslate_TempConfig[parent.configKey] or "zh"
        local idx = GetLanguageIndex(code) - 1
        if idx < parent.minIndex then idx = table.getn(LANGUAGES) end
        WoWTranslate_TempConfig[parent.configKey] = LANGUAGES[idx].code
        parent.display:SetText(LANGUAGES[idx].name)
    end)

    rightBtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        local code = WoWTranslate_TempConfig[parent.configKey] or "zh"
        local idx = GetLanguageIndex(code) + 1
        if idx > table.getn(LANGUAGES) then idx = parent.minIndex end
        WoWTranslate_TempConfig[parent.configKey] = LANGUAGES[idx].code
        parent.display:SetText(LANGUAGES[idx].name)
    end)

    return frame
end

-- ============================================================================
-- BUILD UI (with better spacing, including credits)
-- ============================================================================

-- Y positions with better spacing
local Y_API_HEADER = -50
local Y_API_LABEL = -78
local Y_API_EDIT = -100

-- Usage / budget display (3 lines: spent, budget, session savings)
local Y_CREDITS = -135
-- (Incoming/Outgoing positions now live on their tab pages; see TAB BAR below.)

-- API Settings Section
CreateHeader("API Settings", Y_API_HEADER)

local apiLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
apiLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_API_LABEL)
apiLabel:SetText("WoWTranslate API Key:")  -- Updated label

local apiDisplay = configFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
apiDisplay:SetPoint("LEFT", apiLabel, "RIGHT", 10, 0)
apiDisplay:SetWidth(200)
apiDisplay:SetJustifyH("LEFT")
configFrame.elements.apiDisplay = apiDisplay

local apiEditBg = CreateFrame("Frame", nil, configFrame)
apiEditBg:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_API_EDIT)
apiEditBg:SetWidth(280)
apiEditBg:SetHeight(26)
apiEditBg:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
apiEditBg:SetBackdropColor(0, 0, 0, 0.8)

local apiEdit = CreateFrame("EditBox", nil, apiEditBg)
apiEdit:SetPoint("TOPLEFT", 6, -6)
apiEdit:SetPoint("BOTTOMRIGHT", -6, 6)
apiEdit:SetFontObject(GameFontHighlight)
apiEdit:SetAutoFocus(false)
apiEdit:SetScript("OnEscapePressed", function() this:ClearFocus() end)
apiEdit:SetScript("OnEnterPressed", function() this:ClearFocus() end)
configFrame.elements.apiEdit = apiEdit

local applyApiBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
applyApiBtn:SetPoint("LEFT", apiEditBg, "RIGHT", 15, 0)
applyApiBtn:SetWidth(70)
applyApiBtn:SetHeight(26)
applyApiBtn:SetText("Apply")
applyApiBtn:SetScript("OnClick", function()
    local newKey = configFrame.elements.apiEdit:GetText()
    if newKey and newKey ~= "" then
        WoWTranslateDB.apiKey = newKey
        WoWTranslate_TempConfig.apiKey = newKey
        if WoWTranslate_API and WoWTranslate_API.SetKey then
            local success, err = WoWTranslate_API.SetKey(newKey)
            if success then
                DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] API key applied!|r")
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Failed: " .. (err or "unknown") .. "|r")
            end
        end
        configFrame.elements.apiDisplay:SetText(MaskApiKey(newKey))
        configFrame.elements.apiEdit:SetText("")
        configFrame.elements.apiEdit:ClearFocus()
    end
end)

-- Line 1: real spend this month (Claude backend = your own API key)
local creditsLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
creditsLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_CREDITS)
creditsLabel:SetText("Spent:")

local creditsDisplay = configFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
creditsDisplay:SetPoint("LEFT", creditsLabel, "RIGHT", 10, 0)
creditsDisplay:SetWidth(330)
creditsDisplay:SetJustifyH("LEFT")
creditsDisplay:SetTextColor(0.2, 0.8, 0.2)  -- Green
creditsDisplay:SetText("Unknown")
configFrame.elements.creditsDisplay = creditsDisplay

-- Line 2: budget (self-imposed monthly cap) + low warning
local budgetLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
budgetLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_CREDITS - 20)
budgetLabel:SetText("Budget:")

local budgetDisplay = configFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
budgetDisplay:SetPoint("LEFT", budgetLabel, "RIGHT", 10, 0)
budgetDisplay:SetWidth(240)
budgetDisplay:SetJustifyH("LEFT")
budgetDisplay:SetText("unlimited (your own API key)")
configFrame.elements.budgetDisplay = budgetDisplay

local creditsWarning = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
creditsWarning:SetPoint("LEFT", budgetDisplay, "RIGHT", 8, 0)
creditsWarning:SetTextColor(1, 0.5, 0)  -- Orange
creditsWarning:SetText("")
configFrame.elements.creditsWarning = creditsWarning

-- Line 3: session cache savings
local savingsLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
savingsLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_CREDITS - 40)
savingsLabel:SetText("Session savings:")

local savingsDisplay = configFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
savingsDisplay:SetPoint("LEFT", savingsLabel, "RIGHT", 10, 0)
savingsDisplay:SetWidth(250)
savingsDisplay:SetJustifyH("LEFT")
savingsDisplay:SetTextColor(0.2, 0.8, 0.2)  -- Green
savingsDisplay:SetText("No cache hits yet")
configFrame.elements.savingsDisplay = savingsDisplay

-- ============================================================================
-- TRANSLATION SECTIONS (single page; the source language is ALWAYS auto-detected,
-- so each direction only asks "translate INTO what?")
-- ============================================================================

-- ---- Incoming: chat you receive ----
CreateHeader("Incoming  (chat -> me)", -190)
configFrame.elements.inEnabled = CreateCheckbox("Enable Incoming Translation", 25, -218, "enabled", nil)
configFrame.elements.afkDisable = CreateCheckbox("Disable while AFK", 250, -218, "disableWhileAfk", nil)
configFrame.elements.translateSystem = CreateCheckbox("Translate system/emotes", 25, -244, "translateSystemMessages", nil)
-- Everything NOT understood gets translated into this language.
configFrame.elements.inTo = CreateLangSelector("Translate to:", 25, -274, "incomingToLang", nil, false)

-- Languages you already read -> left untranslated (5 per row).
local uLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
uLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, -330)
uLabel:SetText("Don't translate:")
local U_X = { 25, 100, 175, 250, 325 }
for i, lng in ipairs(UNDERSTAND_LANGS) do
    local col = math.mod(i - 1, 5) + 1
    local yy = (i <= 5) and -352 or -376
    configFrame.elements["und_" .. lng.code] =
        CreateCheckbox(lng.label, U_X[col], yy, "understoodLangs", lng.code)
end

local inChLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
inChLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, -406)
inChLabel:SetText("Incoming Channels:")

configFrame.elements.inChSay = CreateCheckbox("Say", 25, -428, "incomingChannels", "SAY")
configFrame.elements.inChYell = CreateCheckbox("Yell", 140, -428, "incomingChannels", "YELL")
configFrame.elements.inChWhisper = CreateCheckbox("Whisper", 255, -428, "incomingChannels", "WHISPER")
configFrame.elements.inChParty = CreateCheckbox("Party", 25, -454, "incomingChannels", "PARTY")
configFrame.elements.inChGuild = CreateCheckbox("Guild", 140, -454, "incomingChannels", "GUILD")
configFrame.elements.inChRaid = CreateCheckbox("Raid", 255, -454, "incomingChannels", "RAID")
configFrame.elements.inChBG = CreateCheckbox("Battleground", 25, -480, "incomingChannels", "BATTLEGROUND")
configFrame.elements.inChChannel = CreateCheckbox("World/Local", 165, -480, "incomingChannels", "CHANNEL")

-- ---- Outgoing: what you send ----
CreateHeader("Outgoing  (me -> chat)", -518)
configFrame.elements.outEnabled = CreateCheckbox("Enable Outgoing Translation", 25, -546, "outgoingEnabled", nil)
-- Source auto-detected (your own text) -> only choose the language to SEND in.
configFrame.elements.outTo = CreateLangSelector("Translate to:", 25, -576, "outgoingToLang", nil, false)

local outChLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
outChLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, -634)
outChLabel:SetText("Outgoing Channels:")

configFrame.elements.chWhisper = CreateCheckbox("Whisper", 25, -656, "outgoingChannels", "WHISPER")
configFrame.elements.chParty = CreateCheckbox("Party", 140, -656, "outgoingChannels", "PARTY")
configFrame.elements.chSay = CreateCheckbox("Say", 255, -656, "outgoingChannels", "SAY")
configFrame.elements.chGuild = CreateCheckbox("Guild", 25, -682, "outgoingChannels", "GUILD")
configFrame.elements.chRaid = CreateCheckbox("Raid", 140, -682, "outgoingChannels", "RAID")
configFrame.elements.chYell = CreateCheckbox("Yell", 255, -682, "outgoingChannels", "YELL")
configFrame.elements.chBG = CreateCheckbox("Battleground", 25, -708, "outgoingChannels", "BATTLEGROUND")
configFrame.elements.chChannel = CreateCheckbox("World/Local", 165, -708, "outgoingChannels", "CHANNEL")

-- Divider above the action buttons.
local btnDivider = configFrame:CreateTexture(nil, "ARTWORK")
btnDivider:SetTexture(1, 0.82, 0, 0.30)
btnDivider:SetHeight(1)
btnDivider:SetWidth(370)
btnDivider:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", 25, 58)

-- Bottom Buttons
local clearBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
clearBtn:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", 25, 20)
clearBtn:SetWidth(120)
clearBtn:SetHeight(26)
clearBtn:SetText("Clear Cache")
clearBtn:SetScript("OnClick", function()
    if WoWTranslate_CacheClear then
        WoWTranslate_CacheClear()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate] Cache cleared|r")
    end
end)

local saveBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
saveBtn:SetPoint("BOTTOMRIGHT", configFrame, "BOTTOMRIGHT", -25, 20)
saveBtn:SetWidth(80)
saveBtn:SetHeight(26)
saveBtn:SetText("Save")
saveBtn:SetScript("OnClick", function()
    SaveTempConfig()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Settings saved!|r")
    configFrame:Hide()
end)

-- ============================================================================
-- USAGE / BUDGET DISPLAY
-- ============================================================================
-- Refreshes the spent/budget/savings lines from the cached API values.
local function UpdateUsageDisplay()
    local e = configFrame.elements
    local api = WoWTranslate_API

    if e.creditsDisplay then
        if api and api.GetSpentFormatted then
            e.creditsDisplay:SetText(api.GetSpentFormatted())
        else
            e.creditsDisplay:SetText("Unknown")
        end
    end

    if e.budgetDisplay then
        if api and api.GetBudgetFormatted then
            e.budgetDisplay:SetText(api.GetBudgetFormatted())
        else
            e.budgetDisplay:SetText("unlimited (your own API key)")
        end
    end

    if e.creditsWarning then
        if api and api.IsBudgetLow and api.IsBudgetLow() then
            e.creditsWarning:SetText("(budget nearly used!)")
        else
            e.creditsWarning:SetText("")
        end
    end

    if e.savingsDisplay then
        if api and api.GetCacheSavingsFormatted then
            e.savingsDisplay:SetText(api.GetCacheSavingsFormatted())
        else
            e.savingsDisplay:SetText("No cache hits yet")
        end
    end
end

-- ============================================================================
-- REFRESH UI FROM CONFIG
-- ============================================================================
local function RefreshUI()
    local e = configFrame.elements
    local cfg = WoWTranslate_TempConfig

    if e.apiDisplay then
        e.apiDisplay:SetText(MaskApiKey(cfg.apiKey or ""))
    end
    if e.apiEdit then
        e.apiEdit:SetText("")
    end

    -- Update spend / budget / savings display
    UpdateUsageDisplay()

    if e.inEnabled then e.inEnabled:SetChecked(cfg.enabled) end
    if e.afkDisable then e.afkDisable:SetChecked(cfg.disableWhileAfk) end
    if e.translateSystem then e.translateSystem:SetChecked(cfg.translateSystemMessages) end
    if e.outEnabled then e.outEnabled:SetChecked(cfg.outgoingEnabled) end

    -- Source is always auto-detected now; only the two targets are user-set.
    -- "auto" is not a valid target -- coerce any stale value to a concrete one.
    if cfg.incomingToLang == "auto" then cfg.incomingToLang = "en" end
    if cfg.outgoingToLang == "auto" then cfg.outgoingToLang = "zh" end
    if e.inTo and e.inTo.display then
        e.inTo.display:SetText(GetLanguageName(cfg.incomingToLang or "en"))
    end
    if e.outTo and e.outTo.display then
        e.outTo.display:SetText(GetLanguageName(cfg.outgoingToLang or "zh"))
    end

    -- Incoming channels
    local inCh = cfg.incomingChannels or {}
    if e.inChSay then e.inChSay:SetChecked(inCh.SAY) end
    if e.inChYell then e.inChYell:SetChecked(inCh.YELL) end
    if e.inChWhisper then e.inChWhisper:SetChecked(inCh.WHISPER) end
    if e.inChParty then e.inChParty:SetChecked(inCh.PARTY) end
    if e.inChGuild then e.inChGuild:SetChecked(inCh.GUILD) end
    if e.inChRaid then e.inChRaid:SetChecked(inCh.RAID) end
    if e.inChBG then e.inChBG:SetChecked(inCh.BATTLEGROUND) end
    if e.inChChannel then e.inChChannel:SetChecked(inCh.CHANNEL) end

    -- "I understand" grid
    local understood = cfg.understoodLangs or {}
    for _, lng in ipairs(UNDERSTAND_LANGS) do
        local cb = e["und_" .. lng.code]
        if cb then cb:SetChecked(understood[lng.code]) end
    end

    -- Outgoing channels
    local ch = cfg.outgoingChannels or {}
    if e.chWhisper then e.chWhisper:SetChecked(ch.WHISPER) end
    if e.chParty then e.chParty:SetChecked(ch.PARTY) end
    if e.chSay then e.chSay:SetChecked(ch.SAY) end
    if e.chGuild then e.chGuild:SetChecked(ch.GUILD) end
    if e.chRaid then e.chRaid:SetChecked(ch.RAID) end
    if e.chYell then e.chYell:SetChecked(ch.YELL) end
    if e.chBG then e.chBG:SetChecked(ch.BATTLEGROUND) end
    if e.chChannel then e.chChannel:SetChecked(ch.CHANNEL) end
end

-- ============================================================================
-- CREDITS UPDATE TIMER
-- ============================================================================
-- Update credits display periodically when config is open
local creditsUpdateFrame = CreateFrame("Frame")
local creditsUpdateElapsed = 0

creditsUpdateFrame:SetScript("OnUpdate", function()
    if not configFrame:IsVisible() then return end

    creditsUpdateElapsed = creditsUpdateElapsed + arg1
    if creditsUpdateElapsed >= 2 then  -- Update every 2 seconds
        creditsUpdateElapsed = 0

        -- Pull fresh numbers from the proxy (free, no Claude call), then redraw.
        if WoWTranslate_API and WoWTranslate_API.FetchStats then
            WoWTranslate_API.FetchStats()
        end
        UpdateUsageDisplay()
    end
end)

-- ============================================================================
-- PUBLIC API
-- ============================================================================
function WoWTranslate_ShowConfig()
    LoadTempConfig()
    RefreshUI()
    if WoWTranslate_API and WoWTranslate_API.FetchStats then
        WoWTranslate_API.FetchStats()
    end
    configFrame:Show()
end

function WoWTranslate_HideConfig()
    configFrame:Hide()
end

function WoWTranslate_ToggleConfig()
    if configFrame:IsVisible() then
        configFrame:Hide()
    else
        WoWTranslate_ShowConfig()
    end
end
