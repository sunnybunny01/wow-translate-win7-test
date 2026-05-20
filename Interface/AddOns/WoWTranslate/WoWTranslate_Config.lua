-- WoWTranslate_Config.lua
-- Configuration UI panel for WoWTranslate
-- v0.13: Removed API key/credits UI; added source language checkboxes

-- ============================================================================
-- LANGUAGES
-- ============================================================================
local LANGUAGES = {
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
-- CREATE MAIN FRAME
-- ============================================================================
local configFrame = CreateFrame("Frame", "WoWTranslateConfigFrame", UIParent)
configFrame:Hide()
configFrame:SetWidth(480)
configFrame:SetHeight(820)
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
    return header
end

-- ============================================================================
-- HELPER: Create Checkbox at specific position
-- ============================================================================
local function CreateCheckbox(label, xPos, yPos, configKey, subKey)
    -- Create a wrapper frame like the language selector does
    local wrapper = CreateFrame("Frame", nil, configFrame)
    wrapper:SetPoint("TOPLEFT", configFrame, "TOPLEFT", xPos, yPos)
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
local function CreateLangSelector(label, xPos, yPos, configKey)
    local frame = CreateFrame("Frame", nil, configFrame)
    frame:SetPoint("TOPLEFT", configFrame, "TOPLEFT", xPos, yPos)
    frame:SetWidth(170)
    frame:SetHeight(50)

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
        if idx < 1 then idx = table.getn(LANGUAGES) end
        WoWTranslate_TempConfig[parent.configKey] = LANGUAGES[idx].code
        parent.display:SetText(LANGUAGES[idx].name)
    end)

    rightBtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        local code = WoWTranslate_TempConfig[parent.configKey] or "zh"
        local idx = GetLanguageIndex(code) + 1
        if idx > table.getn(LANGUAGES) then idx = 1 end
        WoWTranslate_TempConfig[parent.configKey] = LANGUAGES[idx].code
        parent.display:SetText(LANGUAGES[idx].name)
    end)

    return frame
end

-- ============================================================================
-- BUILD UI
-- ============================================================================

local Y_IN_HEADER  = -50
local Y_IN_ENABLE  = -80
local Y_IN_NAMES   = -110
local Y_IN_LANG    = -145

local Y_SRC_LABEL  = -205
local Y_SRC_ROW    = -230

local Y_SRC_ROW2 = -260

local Y_IN_CH_LABEL = -300
local Y_IN_CH_ROW1 = -325
local Y_IN_CH_ROW2 = -355
local Y_IN_CH_ROW3 = -385

local Y_OUT_HEADER = -420
local Y_OUT_ENABLE = -450
local Y_OUT_LANG   = -485

local Y_CH_LABEL   = -555
local Y_CH_ROW1    = -580
local Y_CH_ROW2    = -610
local Y_CH_ROW3    = -640

-- Incoming Translation Section
CreateHeader("Incoming Translation (Chat -> You)", Y_IN_HEADER)
configFrame.elements.inEnabled = CreateCheckbox("Enable Incoming Translation", 25, Y_IN_ENABLE, "enabled", nil)
configFrame.elements.afkDisable = CreateCheckbox("Disable while AFK", 250, Y_IN_ENABLE, "disableWhileAfk", nil)
configFrame.elements.translateSystem = CreateCheckbox("Translate system/emotes", 25, Y_IN_NAMES, "translateSystemMessages", nil)
configFrame.elements.inTo = CreateLangSelector("To:", 25, Y_IN_LANG, "incomingToLang")

-- Source Language Selection (replaces FROM dropdown)
local srcLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
srcLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_SRC_LABEL)
srcLabel:SetText("Translate incoming from:")

configFrame.elements.srcZH = CreateCheckbox("Chinese",  25,  Y_SRC_ROW, "enabledSourceLangs", "zh")
configFrame.elements.srcJA = CreateCheckbox("Japanese", 135, Y_SRC_ROW, "enabledSourceLangs", "ja")
configFrame.elements.srcKO = CreateCheckbox("Korean",   245, Y_SRC_ROW, "enabledSourceLangs", "ko")
configFrame.elements.srcRU = CreateCheckbox("Russian",  340, Y_SRC_ROW, "enabledSourceLangs", "ru")
configFrame.elements.srcEN = CreateCheckbox("English",  25,  Y_SRC_ROW2, "enabledSourceLangs", "en")

-- Incoming Channels Section
local inChLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
inChLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_IN_CH_LABEL)
inChLabel:SetText("Translate Incoming Channels:")

-- Row 1: Say, Yell, Whisper
configFrame.elements.inChSay = CreateCheckbox("Say", 25, Y_IN_CH_ROW1, "incomingChannels", "SAY")
configFrame.elements.inChYell = CreateCheckbox("Yell", 140, Y_IN_CH_ROW1, "incomingChannels", "YELL")
configFrame.elements.inChWhisper = CreateCheckbox("Whisper", 255, Y_IN_CH_ROW1, "incomingChannels", "WHISPER")

-- Row 2: Party, Guild, Raid, English
configFrame.elements.inChParty = CreateCheckbox("Party", 25, Y_IN_CH_ROW2, "incomingChannels", "PARTY")
configFrame.elements.inChGuild = CreateCheckbox("Guild", 140, Y_IN_CH_ROW2, "incomingChannels", "GUILD")
configFrame.elements.inChRaid = CreateCheckbox("Raid", 255, Y_IN_CH_ROW2, "incomingChannels", "RAID")
configFrame.elements.inChEnglish = CreateCheckbox("English", 370, Y_IN_CH_ROW2, "incomingChannels", "ENGLISH")

-- Row 3: BG, Channel, Hardcore
configFrame.elements.inChBG = CreateCheckbox("Battleground", 25, Y_IN_CH_ROW3, "incomingChannels", "BATTLEGROUND")
configFrame.elements.inChChannel = CreateCheckbox("World/Local", 165, Y_IN_CH_ROW3, "incomingChannels", "CHANNEL")
configFrame.elements.inChHC = CreateCheckbox("Hardcore", 310, Y_IN_CH_ROW3, "incomingChannels", "HARDCORE")

-- Outgoing Translation Section
CreateHeader("Outgoing Translation (You -> Chat)", Y_OUT_HEADER)
configFrame.elements.outEnabled = CreateCheckbox("Enable Outgoing Translation", 25, Y_OUT_ENABLE, "outgoingEnabled", nil)
configFrame.elements.outPrefix = CreateCheckbox("Send prefix with translation", 250, Y_OUT_ENABLE, "outgoingPrefixEnabled", nil)
configFrame.elements.outFrom = CreateLangSelector("From:", 25, Y_OUT_LANG, "outgoingFromLang")
configFrame.elements.outTo = CreateLangSelector("To:", 210, Y_OUT_LANG, "outgoingToLang")

-- Channels Section
local chLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
chLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_CH_LABEL)
chLabel:SetText("Outgoing Channels:")

-- Row 1: Whisper, Party, Say (spaced evenly)
configFrame.elements.chWhisper = CreateCheckbox("Whisper", 25, Y_CH_ROW1, "outgoingChannels", "WHISPER")
configFrame.elements.chParty = CreateCheckbox("Party", 140, Y_CH_ROW1, "outgoingChannels", "PARTY")
configFrame.elements.chSay = CreateCheckbox("Say", 255, Y_CH_ROW1, "outgoingChannels", "SAY")

-- Row 2: Guild, Raid, Yell, English (spaced evenly)
configFrame.elements.chGuild = CreateCheckbox("Guild", 25, Y_CH_ROW2, "outgoingChannels", "GUILD")
configFrame.elements.chRaid = CreateCheckbox("Raid", 140, Y_CH_ROW2, "outgoingChannels", "RAID")
configFrame.elements.chYell = CreateCheckbox("Yell", 255, Y_CH_ROW2, "outgoingChannels", "YELL")
configFrame.elements.chEnglish = CreateCheckbox("English", 370, Y_CH_ROW2, "outgoingChannels", "ENGLISH")

-- Row 3: BG, Channel, Hardcore
configFrame.elements.chBG = CreateCheckbox("Battleground", 25, Y_CH_ROW3, "outgoingChannels", "BATTLEGROUND")
configFrame.elements.chChannel = CreateCheckbox("World/Local", 165, Y_CH_ROW3, "outgoingChannels", "CHANNEL")
configFrame.elements.chHC = CreateCheckbox("Hardcore", 310, Y_CH_ROW3, "outgoingChannels", "HARDCORE")

-- Translation Color Section — all controls on one line.
-- Frames MUST anchor to configFrame (not to FontStrings) in WoW 1.12;
-- FontStrings may anchor to Frames freely.
local Y_COLOR = -673

local colorSectionLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
colorSectionLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_COLOR)
colorSectionLabel:SetText("Translation text color:")
-- "Translation text color:" at GameFontNormal is ~162 px wide; swatch starts at x=196

local colorSwatch = CreateFrame("Button", "WoWTranslateColorSwatch", configFrame)
colorSwatch:SetWidth(30)
colorSwatch:SetHeight(18)
colorSwatch:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 196, Y_COLOR - 2)
colorSwatch:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile     = true, tileSize = 8, edgeSize  = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
})
colorSwatch:SetBackdropBorderColor(0, 0, 0)
colorSwatch:SetBackdropColor(1, 1, 1)

-- FontString anchoring to a Frame is always legal
local colorSwatchLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
colorSwatchLabel:SetPoint("LEFT", colorSwatch, "RIGHT", 6, 0)
colorSwatchLabel:SetText("(click to pick)")
-- "(click to pick)" is ~85 px; Default button starts at x=322

local colorDefaultBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
colorDefaultBtn:SetWidth(70)
colorDefaultBtn:SetHeight(18)
colorDefaultBtn:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 322, Y_COLOR - 2)
colorDefaultBtn:SetText("Default")

local function ApplyTranslationColor(hex)
    WoWTranslate_TempConfig.translationColor = hex
    if WoWTranslateDB then WoWTranslateDB.translationColor = hex end
    if hex and string.len(hex) == 6 then
        local r = tonumber(string.sub(hex, 1, 2), 16) / 255
        local g = tonumber(string.sub(hex, 3, 4), 16) / 255
        local b = tonumber(string.sub(hex, 5, 6), 16) / 255
        colorSwatch:SetBackdropColor(r, g, b)
    else
        colorSwatch:SetBackdropColor(0.5, 0.5, 0.5)  -- gray = default (no override)
    end
end

colorSwatch:SetScript("OnClick", function()
    local hex = (WoWTranslateDB and WoWTranslateDB.translationColor) or ""
    local r, g, b = 1, 1, 1
    if hex and string.len(hex) == 6 then
        r = tonumber(string.sub(hex, 1, 2), 16) / 255
        g = tonumber(string.sub(hex, 3, 4), 16) / 255
        b = tonumber(string.sub(hex, 5, 6), 16) / 255
    end
    ColorPickerFrame.hasOpacity = false
    ColorPickerFrame.func = function()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        local nhex = string.format("%02X%02X%02X",
            math.floor(nr * 255), math.floor(ng * 255), math.floor(nb * 255))
        ApplyTranslationColor(nhex)
    end
    ColorPickerFrame.cancelFunc = function(pv)
        local pr, pg, pb = pv[1], pv[2], pv[3]
        local phex = string.format("%02X%02X%02X",
            math.floor(pr * 255), math.floor(pg * 255), math.floor(pb * 255))
        ApplyTranslationColor(phex)
    end
    ColorPickerFrame.previousValues = { r, g, b }
    ColorPickerFrame:SetColorRGB(r, g, b)
    -- Ensure the picker appears above our DIALOG-strata config frame
    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    ShowUIPanel(ColorPickerFrame)
end)

colorDefaultBtn:SetScript("OnClick", function()
    ApplyTranslationColor("")
end)

configFrame.elements.colorSwatch = colorSwatch

-- Second color row: opt in to using the source channel's native color for the body.
-- When checked, the custom swatch color is ignored.
local Y_COLOR_FOLLOW = -698
configFrame.elements.colorFollow = CreateCheckbox("Follow channel color", 25, Y_COLOR_FOLLOW, "translationColorFollow", nil)

-- Experimental Section
local Y_EXP_HEADER = -725
local expHeader = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
expHeader:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_EXP_HEADER)
expHeader:SetText("Experimental:")
expHeader:SetTextColor(1, 0.5, 0)

local Y_EXP_ROW = -748
configFrame.elements.replaceMode = CreateCheckbox("Replace original with translation (may delay/lose messages)", 25, Y_EXP_ROW, "replaceMode", nil)

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
-- REFRESH UI FROM CONFIG
-- ============================================================================
local function RefreshUI()
    local e = configFrame.elements
    local cfg = WoWTranslate_TempConfig

    if e.colorSwatch then
        local hex = cfg.translationColor or ""
        if hex and string.len(hex) == 6 then
            local r = tonumber(string.sub(hex, 1, 2), 16) / 255
            local g = tonumber(string.sub(hex, 3, 4), 16) / 255
            local b = tonumber(string.sub(hex, 5, 6), 16) / 255
            e.colorSwatch:SetBackdropColor(r, g, b)
        else
            e.colorSwatch:SetBackdropColor(0.5, 0.5, 0.5)
        end
    end
    if e.colorFollow then e.colorFollow:SetChecked(cfg.translationColorFollow) end
    if e.replaceMode then e.replaceMode:SetChecked(cfg.replaceMode) end
    if e.inEnabled then e.inEnabled:SetChecked(cfg.enabled) end
    if e.afkDisable then e.afkDisable:SetChecked(cfg.disableWhileAfk) end
    if e.translateSystem then e.translateSystem:SetChecked(cfg.translateSystemMessages) end
    if e.outEnabled then e.outEnabled:SetChecked(cfg.outgoingEnabled) end
    if e.outPrefix then e.outPrefix:SetChecked(cfg.outgoingPrefixEnabled) end

    -- Source language checkboxes
    local srcLangs = cfg.enabledSourceLangs or {}
    if e.srcZH then e.srcZH:SetChecked(srcLangs.zh) end
    if e.srcJA then e.srcJA:SetChecked(srcLangs.ja) end
    if e.srcKO then e.srcKO:SetChecked(srcLangs.ko) end
    if e.srcRU then e.srcRU:SetChecked(srcLangs.ru) end
    if e.srcEN then e.srcEN:SetChecked(srcLangs.en) end

    if e.inTo and e.inTo.display then
        e.inTo.display:SetText(GetLanguageName(cfg.incomingToLang or "en"))
    end
    if e.outFrom and e.outFrom.display then
        e.outFrom.display:SetText(GetLanguageName(cfg.outgoingFromLang or "en"))
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
    if e.inChHC then e.inChHC:SetChecked(inCh.HARDCORE) end
    if e.inChEnglish then e.inChEnglish:SetChecked(inCh.ENGLISH) end

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
    if e.chHC then e.chHC:SetChecked(ch.HARDCORE) end
    if e.chEnglish then e.chEnglish:SetChecked(ch.ENGLISH) end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================
function WoWTranslate_ShowConfig()
    LoadTempConfig()
    RefreshUI()
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
