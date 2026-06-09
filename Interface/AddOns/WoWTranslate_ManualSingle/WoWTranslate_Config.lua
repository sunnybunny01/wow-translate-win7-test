-- WoWTranslate_Config.lua
-- 翻译插件配置界面
-- v0.13: 移除API密钥/贡献者界面；添加源语言复选框

-- ============================================================================
-- 语言列表
-- ============================================================================
local LANGUAGES = {
    { code = "zh", name = "中文" },
    { code = "en", name = "英文" },
    { code = "ko", name = "韩文" },
    { code = "ja", name = "日文" },
    { code = "ru", name = "俄文" },
    { code = "de", name = "德文" },
    { code = "fr", name = "法文" },
    { code = "es", name = "西班牙文" },
    { code = "pt", name = "葡萄牙文" },
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
-- 临时配置
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
-- 创建主窗口
-- ============================================================================
local configFrame = CreateFrame("Frame", "WoWTranslateConfigFrame", UIParent)
configFrame:Hide()
configFrame:SetWidth(580)
configFrame:SetHeight(800)
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

-- 标题
local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOP", configFrame, "TOP", 0, -20)
title:SetText("聊天翻译设置 - v1.5 -夏姬汉化")

-- 关闭按钮
local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function()
    configFrame:Hide()
end)

-- ESC关闭窗口
tinsert(UISpecialFrames, "WoWTranslateConfigFrame")

-- ============================================================================
-- 界面元素存储
-- ============================================================================
configFrame.elements = {}

-- ============================================================================
-- 辅助函数：创建分区标题
-- ============================================================================
local function CreateHeader(text, yPos)
    local header = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, yPos)
    header:SetText(text)
    header:SetTextColor(0, 1, 1)
    return header
end

-- ============================================================================
-- 辅助函数：在指定位置创建复选框
-- ============================================================================
local function CreateCheckbox(label, xPos, yPos, configKey, subKey)
    -- 创建包裹框架，与语言选择器保持一致
    local wrapper = CreateFrame("Frame", nil, configFrame)
    wrapper:SetPoint("TOPLEFT", configFrame, "TOPLEFT", xPos, yPos)
    wrapper:SetWidth(200)
    wrapper:SetHeight(22)

    -- 在包裹框架上存储配置项（与语言选择器相同格式）
    wrapper.configKey = configKey
    wrapper.subKey = subKey

    local cb = CreateFrame("CheckButton", nil, wrapper, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 0, 0)

    local text = wrapper:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)

    cb:SetScript("OnClick", function()
        -- 使用GetParent()，与语言选择器逻辑一致
        local parent = this:GetParent()
        local key = parent.configKey
        local sub = parent.subKey

        -- 魔兽1.12版本中GetChecked()返回1或空值
        local isChecked = this:GetChecked()
        local enabled = (isChecked and true) or false

        -- 使用全局开关函数实现即时生效
        if key == "translateNameplates" then
            WoWTranslate_SetTranslateNameplates(enabled)
            WoWTranslate_TempConfig.translateNameplates = enabled
        elseif key == "translatePlayerNames" then
            WoWTranslate_SetTranslatePlayerNames(enabled)
            WoWTranslate_TempConfig.translatePlayerNames = enabled
        elseif key == "translateGuildNames" then
            WoWTranslate_SetTranslateGuildNames(enabled)
            WoWTranslate_TempConfig.translateGuildNames = enabled
        elseif key == "translateGroupFinder" then
            WoWTranslate_SetTranslateGroupFinder(enabled)
            WoWTranslate_TempConfig.translateGroupFinder = enabled
        elseif key == "showOutgoingButton" then
            WoWTranslate_SetOutgoingButtonVisible(enabled)
            WoWTranslate_TempConfig.showOutgoingButton = enabled
        elseif key == "outgoingEnabled" then
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
            -- 其他设置项备用逻辑
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

    -- 返回复选框（非包裹框架），确保SetChecked正常工作
    cb.wrapper = wrapper
    return cb
end

-- ============================================================================
-- 辅助函数：创建语言选择器
-- ============================================================================
local function CreateLangSelector(label, xPos, yPos, configKey)
    local frame = CreateFrame("Frame", nil, configFrame)
    frame:SetPoint("TOPLEFT", configFrame, "TOPLEFT", xPos, yPos)
    frame:SetWidth(170)
    frame:SetHeight(50)

    local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
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
    display:SetText("语言")

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
-- 构建界面
-- ============================================================================

local Y_IN_HEADER    = -50
local Y_IN_ENABLE    = -76
local Y_IN_NAMES     = -101
local Y_IN_LANG      = -130

local Y_SRC_LABEL    = -185
local Y_SRC_ROW      = -208

local Y_IN_CH_LABEL  = -242
local Y_IN_CH_ROW1   = -264
local Y_IN_CH_ROW2   = -289

local Y_OUT_HEADER   = -322
local Y_OUT_ENABLE   = -349
local Y_OUT_LANG     = -378

local Y_CH_LABEL     = -437
local Y_CH_ROW1      = -459
local Y_CH_ROW2      = -484

local Y_COLOR        = -518
local Y_COLOR_FOLLOW = -542

local Y_EXP_HEADER   = -571
local Y_EXP_ROW      = -593

local Y_NAME_HEADER  = -625
local Y_NAME_ROW     = -647

local Y_SP_HEADER    = -679
local Y_SP_ROW1      = -701
local Y_SP_ROW2      = -723

-- 接收翻译设置区
CreateHeader("接收翻译（他人聊天→你）", Y_IN_HEADER)
configFrame.elements.inEnabled     = CreateCheckbox("启用接收翻译", 25,  Y_IN_ENABLE, "enabled", nil)
configFrame.elements.afkDisable    = CreateCheckbox("暂离时自动关闭",          270,  Y_IN_ENABLE, "disableWhileAfk", nil)
configFrame.elements.translateSystem = CreateCheckbox("翻译系统/表情消息",  25,  Y_IN_NAMES,  "translateSystemMessages", nil)
configFrame.elements.inTo          = CreateLangSelector("翻译为：", 25, Y_IN_LANG, "incomingToLang")

local roleInfoText = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
roleInfoText:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -20, Y_IN_LANG - 31)
roleInfoText:SetText("T = 坦克,  N = 治疗,  D = 输出")
roleInfoText:SetTextColor(0.2, 1, 0.2)
roleInfoText:SetFont("Fonts\\FRIZQT__.TTF", 9, "ITALIC")

local otherInfoText = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
otherInfoText:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -20, Y_IN_LANG - 51)
otherInfoText:SetText("M, MM , MMM+ = 密语")
otherInfoText:SetTextColor(1, 0, 1)
otherInfoText:SetFont("Fonts\\FRIZQT__.TTF", 9, "ITALIC")

-- 源语言选择
local srcLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
srcLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_SRC_LABEL)
srcLabel:SetText("翻译以下来源语言：")

configFrame.elements.srcZH = CreateCheckbox("中文",  25,  Y_SRC_ROW, "enabledSourceLangs", "zh")
configFrame.elements.srcJA = CreateCheckbox("日文", 115, Y_SRC_ROW, "enabledSourceLangs", "ja")
configFrame.elements.srcKO = CreateCheckbox("韩文",   210, Y_SRC_ROW, "enabledSourceLangs", "ko")
configFrame.elements.srcRU = CreateCheckbox("俄文",  300, Y_SRC_ROW, "enabledSourceLangs", "ru")
configFrame.elements.srcEN = CreateCheckbox("英文",  390, Y_SRC_ROW, "enabledSourceLangs", "en")

-- 接收频道设置
local inChLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
inChLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_IN_CH_LABEL)
inChLabel:SetText("翻译接收频道：")

-- 第一行：说、大喊、密语、小队、公会
configFrame.elements.inChSay     = CreateCheckbox("说",          25,  Y_IN_CH_ROW1, "incomingChannels", "SAY")
configFrame.elements.inChYell    = CreateCheckbox("大喊",        115,  Y_IN_CH_ROW1, "incomingChannels", "YELL")
configFrame.elements.inChWhisper = CreateCheckbox("密语",     205,  Y_IN_CH_ROW1, "incomingChannels", "WHISPER")
configFrame.elements.inChParty   = CreateCheckbox("小队",       310,  Y_IN_CH_ROW1, "incomingChannels", "PARTY")
configFrame.elements.inChGuild   = CreateCheckbox("公会",       405,  Y_IN_CH_ROW1, "incomingChannels", "GUILD")

-- 第二行：团队、英文、战场、世界/本地、硬核
configFrame.elements.inChRaid    = CreateCheckbox("团队",         25,  Y_IN_CH_ROW2, "incomingChannels", "RAID")
configFrame.elements.inChEnglish = CreateCheckbox("英文",     115,  Y_IN_CH_ROW2, "incomingChannels", "ENGLISH")
configFrame.elements.inChBG      = CreateCheckbox("战场", 210, Y_IN_CH_ROW2, "incomingChannels", "BATTLEGROUND")
configFrame.elements.inChChannel = CreateCheckbox("世界/本地",  315, Y_IN_CH_ROW2, "incomingChannels", "CHANNEL")
configFrame.elements.inChHC      = CreateCheckbox("硬核",     415, Y_IN_CH_ROW2, "incomingChannels", "HARDCORE")

-- 发送翻译设置区
CreateHeader("发送翻译（你→聊天）", Y_OUT_HEADER)
configFrame.elements.outEnabled   = CreateCheckbox("启用发送翻译",  25,  Y_OUT_ENABLE, "outgoingEnabled",       nil)
configFrame.elements.outPrefix    = CreateCheckbox("翻译内容添加前缀",  210, Y_OUT_ENABLE, "outgoingPrefixEnabled", nil)
configFrame.elements.outShowBtn   = CreateCheckbox("显示开关按钮",                 410, Y_OUT_ENABLE, "showOutgoingButton",    nil)
configFrame.elements.outFrom    = CreateLangSelector("原文语言：", 25,  Y_OUT_LANG, "outgoingFromLang")
configFrame.elements.outTo      = CreateLangSelector("翻译为：",  215,  Y_OUT_LANG, "outgoingToLang")

-- 发送频道设置
local chLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
chLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_CH_LABEL)
chLabel:SetText("发送翻译频道：")

-- 第一行：密语、小队、说、公会、团队
configFrame.elements.chWhisper = CreateCheckbox("密语",  25,  Y_CH_ROW1, "outgoingChannels", "WHISPER")
configFrame.elements.chParty   = CreateCheckbox("小队",   115,  Y_CH_ROW1, "outgoingChannels", "PARTY")
configFrame.elements.chSay     = CreateCheckbox("说",     210,  Y_CH_ROW1, "outgoingChannels", "SAY")
configFrame.elements.chGuild   = CreateCheckbox("公会",   300,  Y_CH_ROW1, "outgoingChannels", "GUILD")
configFrame.elements.chRaid    = CreateCheckbox("团队",    390,  Y_CH_ROW1, "outgoingChannels", "RAID")

-- 第二行：大喊、英文、战场、世界/本地、硬核
configFrame.elements.chYell    = CreateCheckbox("大喊",         25,  Y_CH_ROW2, "outgoingChannels", "YELL")
configFrame.elements.chEnglish = CreateCheckbox("英文",     115,  Y_CH_ROW2, "outgoingChannels", "ENGLISH")
configFrame.elements.chBG      = CreateCheckbox("战场", 210, Y_CH_ROW2, "outgoingChannels", "BATTLEGROUND")
configFrame.elements.chChannel = CreateCheckbox("世界/本地",  315, Y_CH_ROW2, "outgoingChannels", "CHANNEL")
configFrame.elements.chHC      = CreateCheckbox("硬核",     415, Y_CH_ROW2, "outgoingChannels", "HARDCORE")

-- 翻译文字颜色设置 — 所有控件在同一行
-- 魔兽1.12版本中，框架必须锚定到主窗口（而非文字）；文字可自由锚定到框架
local colorSectionLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
colorSectionLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_COLOR)
colorSectionLabel:SetText("翻译文字颜色：")

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

local colorSwatchLabel = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
colorSwatchLabel:SetPoint("LEFT", colorSwatch, "RIGHT", 6, 0)
colorSwatchLabel:SetText("(点击选择)")

local colorDefaultBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
colorDefaultBtn:SetWidth(70)
colorDefaultBtn:SetHeight(18)
colorDefaultBtn:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 322, Y_COLOR - 2)
colorDefaultBtn:SetText("默认颜色")

local function ApplyTranslationColor(hex)
    WoWTranslate_TempConfig.translationColor = hex
    if WoWTranslateDB then WoWTranslateDB.translationColor = hex end
    if hex and string.len(hex) == 6 then
        local r = tonumber(string.sub(hex, 1, 2), 16) / 255
        local g = tonumber(string.sub(hex, 3, 4), 16) / 255
        local b = tonumber(string.sub(hex, 5, 6), 16) / 255
        colorSwatch:SetBackdropColor(r, g, b)
    else
        colorSwatch:SetBackdropColor(0.5, 0.5, 0.5)
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
    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    ShowUIPanel(ColorPickerFrame)
end)

colorDefaultBtn:SetScript("OnClick", function()
    ApplyTranslationColor("")
end)

configFrame.elements.colorSwatch = colorSwatch

configFrame.elements.colorFollow = CreateCheckbox("跟随频道颜色", 25, Y_COLOR_FOLLOW, "translationColorFollow", nil)

-- 实验性功能
local expHeader = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
expHeader:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_EXP_HEADER)
expHeader:SetText("实验性功能：")
expHeader:SetTextColor(1, 0.5, 0)

configFrame.elements.replaceMode      = CreateCheckbox("替换原文显示翻译", 25,  Y_EXP_ROW, "replaceMode", nil)
configFrame.elements.translateGF      = CreateCheckbox("翻译组队查找器",           270, Y_EXP_ROW, "translateGroupFinder", nil)

-- 名字翻译设置
CreateHeader("名字翻译：", Y_NAME_HEADER)
configFrame.elements.translateNames  = CreateCheckbox("发送者名字（聊天/鼠标提示）", 25,  Y_NAME_ROW, "translatePlayerNames", nil)
configFrame.elements.translateGuilds = CreateCheckbox("公会名字（鼠标提示）",       290, Y_NAME_ROW, "translateGuildNames", nil)

-- ShaguPlates插件兼容设置
local spHeader = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
spHeader:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 25, Y_SP_HEADER)
spHeader:SetText("姓名板插件(ShaguPlates)：")
spHeader:SetTextColor(0, 1, 1)

configFrame.elements.translateNP    = CreateCheckbox("翻译姓名板",        25,  Y_SP_ROW1, "translateNameplates",   nil)
configFrame.elements.npClassColor   = CreateCheckbox("名字显示职业颜色",         290, Y_SP_ROW1, "playerNameClassColor",  nil)
configFrame.elements.npGuildOOC     = CreateCheckbox("脱战时显示公会",        25,  Y_SP_ROW2, "nameplateGuildOOC",     nil)
configFrame.elements.npHideHealth   = CreateCheckbox("脱战时隐藏血条", 290, Y_SP_ROW2, "nameplateHideHealthOOC", nil)

-- 底部按钮
local clearBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
clearBtn:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", 25, 12)
clearBtn:SetWidth(120)
clearBtn:SetHeight(26)
clearBtn:SetText("清空缓存")
clearBtn:SetScript("OnClick", function()
    if WoWTranslate_CacheClear then
        WoWTranslate_CacheClear()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[聊天翻译] 缓存已清空|r")
    end
end)

local saveBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
saveBtn:SetPoint("BOTTOMRIGHT", configFrame, "BOTTOMRIGHT", -25, 12)
saveBtn:SetWidth(80)
saveBtn:SetHeight(26)
saveBtn:SetText("保存")
saveBtn:SetScript("OnClick", function()
    SaveTempConfig()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[聊天翻译] 设置已保存！|r")
    configFrame:Hide()
end)

-- ============================================================================
-- 从配置刷新界面
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
    if e.replaceMode    then e.replaceMode:SetChecked(cfg.replaceMode) end
    if e.translateGF    then e.translateGF:SetChecked(cfg.translateGroupFinder) end
    if e.translateNames then e.translateNames:SetChecked(cfg.translatePlayerNames) end
    if e.translateGuilds then e.translateGuilds:SetChecked(cfg.translateGuildNames) end
    if e.translateNP    then e.translateNP:SetChecked(cfg.translateNameplates) end
    if e.npClassColor   then e.npClassColor:SetChecked(cfg.playerNameClassColor) end
    if e.npGuildOOC     then e.npGuildOOC:SetChecked(cfg.nameplateGuildOOC) end
    if e.npHideHealth   then e.npHideHealth:SetChecked(cfg.nameplateHideHealthOOC) end
    if e.inEnabled then e.inEnabled:SetChecked(cfg.enabled) end
    if e.afkDisable then e.afkDisable:SetChecked(cfg.disableWhileAfk) end
    if e.translateSystem then e.translateSystem:SetChecked(cfg.translateSystemMessages) end
    if e.outEnabled  then e.outEnabled:SetChecked(cfg.outgoingEnabled) end
    if e.outPrefix   then e.outPrefix:SetChecked(cfg.outgoingPrefixEnabled) end
    if e.outShowBtn  then e.outShowBtn:SetChecked(cfg.showOutgoingButton) end

    -- 源语言复选框
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

    -- 接收频道
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

    -- 发送频道
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
-- 对外接口
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
