-- WoWTranslate.lua
-- Main addon file: chat hooks, display, and coordination
-- Chinese to English translation for WoW 1.12

-- ============================================================================
-- SAVED VARIABLES (initialized on load)
-- ============================================================================
WoWTranslateDB = WoWTranslateDB or {}
WoWTranslateDebugLog = WoWTranslateDebugLog or {}
WoWTranslateManualRecords = WoWTranslateManualRecords or {}

-- ============================================================================
-- LOCAL STATE
-- ============================================================================
local DEBUG_MODE = false
local addonLoaded = false
local originalAddMessage = nil
local playerIsAFK = false
local dllWarnShown = false
local translationErrWarnShown = false
local hookCallCount = 0         -- incremented every time any hook body executes

local pendingMessages = {}
local messageCounter = 0
local manualTranslateFrames = {}
local MANUAL_TRANSLATE_MAX_RECORDS = 500

-- Maps capturedArg1 (raw message text) -> {frame -> true}
-- Collects every chat frame that showed the original Chinese message so the async
-- translation callback can post to all of them.  Multiple frames fire the same
-- OnEvent for one message; dedup lets only the first reach the DLL, but all frames
-- that displayed the original must also show the translation.
local frameTranslationTargets = {}

-- Outgoing translation state
local outgoingQueue = {}
local outgoingCounter = 0
local originalSendChatMessage = SendChatMessage

-- Waiters for in-flight player/guild name translations (rawName -> { callbacks = {} })
local pendingNameTranslations = {}

-- Forward reference: assigned after HookNameplates is defined so
-- WoWTranslate_SetTranslateNameplates can start the scanner mid-session.
local wtNameplateScanStart = nil

-- Pre-translated prefixes for outgoing messages (zero API cost)
local TRANSLATED_PREFIXES = {
    zh = "[由聊天翻译插件翻译]",
    en = "[由聊天翻译插件翻译]",
    ko = "[由聊天翻译插件翻译]",
    ja = "[由聊天翻译插件翻译]",
    ru = "[由聊天翻译插件翻译]",
    de = "[由聊天翻译插件翻译]",
    fr = "[由聊天翻译插件翻译]",
    es = "[由聊天翻译插件翻译]",
    pt = "[由聊天翻译插件翻译]",
}
local DEFAULT_PREFIX = "[由聊天翻译插件翻译]"

-- Incoming channel detection state
local currentIncomingChannel = nil
local currentIsSystemEvent = false  -- True for system/emote/NPC events

local EVENT_TO_CHANNEL = {
    CHAT_MSG_SAY = "SAY",
    CHAT_MSG_YELL = "YELL",
    CHAT_MSG_WHISPER = "WHISPER",
    CHAT_MSG_PARTY = "PARTY",
    CHAT_MSG_GUILD = "GUILD",
    CHAT_MSG_OFFICER = "GUILD",
    CHAT_MSG_RAID = "RAID",
    CHAT_MSG_RAID_LEADER = "RAID",
    CHAT_MSG_RAID_WARNING = "RAID",
    CHAT_MSG_BATTLEGROUND = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER = "BATTLEGROUND",
    CHAT_MSG_CHANNEL = "CHANNEL",
    CHAT_MSG_HARDCORE = "HARDCORE",
}

-- Events to skip translation for (system msgs, emotes, NPC speech, notifications)
-- Only these specific events are skipped; unknown events (like WHISPER_INFORM) still translate
local SYSTEM_EVENTS = {
    CHAT_MSG_SYSTEM = true,
    CHAT_MSG_EMOTE = true,
    CHAT_MSG_TEXT_EMOTE = true,
    CHAT_MSG_MONSTER_SAY = true,
    CHAT_MSG_MONSTER_YELL = true,
    CHAT_MSG_MONSTER_EMOTE = true,
    CHAT_MSG_MONSTER_WHISPER = true,
    CHAT_MSG_CHANNEL_JOIN = true,
    CHAT_MSG_CHANNEL_LEAVE = true,
    CHAT_MSG_LOOT = true,
    CHAT_MSG_MONEY = true,
    CHAT_MSG_OPENING = true,
    CHAT_MSG_SKILL = true,
    CHAT_MSG_COMBAT_HONOR_GAIN = true,
    CHAT_MSG_COMBAT_XP_GAIN = true,
    CHAT_MSG_COMBAT_MISC_INFO = true,
}

local defaults = {
    enabled = true,
    debugMode = false,
    -- Outgoing translation settings
    outgoingEnabled = false,  -- Off by default
    outgoingChannels = {
        WHISPER = true,
        PARTY = true,
        GUILD = true,
        RAID = true,
        SAY = true,
        YELL = true,
        BATTLEGROUND = true,
        CHANNEL = true,
        HARDCORE = false,
        ENGLISH = false,
    },
    incomingChannels = {
        SAY = true,
        YELL = true,
        WHISPER = true,
        PARTY = true,
        GUILD = true,
        RAID = true,
        BATTLEGROUND = true,
        CHANNEL = true,
        HARDCORE = false,
        ENGLISH = false,
    },
    outgoingPrefix = "[由聊天翻译插件翻译]",
    outgoingPrefixEnabled = true,
    disableWhileAfk = false,
    translateSystemMessages = false,  -- Don't translate system msgs, emotes, NPC speech
    -- Language settings (any-to-any translation)
    enabledSourceLangs = { zh = true, ja = true, ko = true, ru = true, en = false },
    incomingToLang = "en",
    outgoingFromLang = "en",
    outgoingToLang = "zh",
    translationColor = "",       -- Hex RRGGBB for translated text body; empty = default chat color
    translationColorFollow = false,  -- If true, body color follows the source channel color
    replaceMode = false,         -- [EXPERIMENTAL] Replace original message with translation instead of appending
    translateGroupFinder = false, -- [EXPERIMENTAL] Translate LFT group finder titles/descriptions
    manualTranslateEnabled = true, -- [EXPERIMENTAL] Click [译] after a chat line to translate only that line
    manualTranslateShowLinks = true,
    -- Name/guild translation
    translatePlayerNames = false,
    translateGuildNames = false,
    translateNameplates = false,
    outgoingButtonPos = { x = 100, y = 100 },
    showOutgoingButton = true,
    playerNameClassColor = true,
    nameplateGuildOOC = false,
    nameplateHideHealthOOC = false,
}

-- ============================================================================
-- LUA 5.0 COMPATIBILITY
-- ============================================================================
local function strsplit(delimiter, text, limit)
    if not text then return nil end
    if not delimiter or delimiter == "" then return text end

    local result = {}
    local count = 0
    local start = 1
    local delimStart, delimEnd = string.find(text, delimiter, start, true)

    while delimStart do
        count = count + 1
        if limit and count >= limit then
            break
        end
        table.insert(result, string.sub(text, start, delimStart - 1))
        start = delimEnd + 1
        delimStart, delimEnd = string.find(text, delimiter, start, true)
    end

    table.insert(result, string.sub(text, start))
    return unpack(result)
end

-- ============================================================================
-- DEBUG LOGGING
-- ============================================================================
local function DebugLog(a1, a2, a3, a4, a5)
    if not DEBUG_MODE then return end

    local msg = ""
    if a1 then msg = msg .. tostring(a1) .. " " end
    if a2 then msg = msg .. tostring(a2) .. " " end
    if a3 then msg = msg .. tostring(a3) .. " " end
    if a4 then msg = msg .. tostring(a4) .. " " end
    if a5 then msg = msg .. tostring(a5) .. " " end

    local timestamp = string.format("%.1f", GetTime())
    local logEntry = "[" .. timestamp .. "] " .. msg

    if originalAddMessage then
        originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFFFF00[聊天翻译-调试] " .. msg .. "|r")
    end

    table.insert(WoWTranslateDebugLog, logEntry)

    while table.getn(WoWTranslateDebugLog) > 500 do
        table.remove(WoWTranslateDebugLog, 1)
    end
end

-- ============================================================================
-- SOURCE LANGUAGE CHARACTER DETECTION
-- ============================================================================
-- Detects if text contains characters from the configured source language
-- Supports: zh (Chinese), ja (Japanese), ko (Korean), ru (Russian)
-- For Latin-based languages (en, de, fr, es, pt): detects non-ASCII characters

local function ContainsLanguageChars(text, lang)
    if not text then return false end

    -- English: pure ASCII text with >= 4 alpha characters.
    -- Any non-ASCII byte (>= 128) means the text contains CJK/Russian/etc., so it is
    -- NOT purely English. Without this guard, Chinese messages that mix in WoW
    -- abbreviations like "MC DPS LFG" (4+ Latin chars) would falsely be detected
    -- as "already English" and skip outgoing translation.
    if lang == "en" then
        local count = 0
        for i = 1, string.len(text) do
            local b = string.byte(text, i)
            if b >= 128 then
                return false  -- non-ASCII character: not a pure English message
            elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
                count = count + 1
            end
        end
        return count >= 4
    end

    for i = 1, string.len(text) do
        local byte = string.byte(text, i)

        if lang == "zh" then
            -- Chinese: CJK Unified Ideographs (U+4E00-U+9FFF)
            -- UTF-8: bytes 228-233 as first byte
            if byte >= 228 and byte <= 233 then
                return true
            end
        elseif lang == "ja" then
            -- Japanese: Hiragana, Katakana, and CJK
            -- Hiragana/Katakana: U+3040-U+30FF (UTF-8: 227 as first byte)
            -- CJK: same as Chinese
            if byte == 227 or (byte >= 228 and byte <= 233) then
                return true
            end
        elseif lang == "ko" then
            -- Korean: Hangul syllables U+AC00-U+D7AF
            -- UTF-8: bytes 234-237 as first byte (covers Hangul range)
            if byte >= 234 and byte <= 237 then
                return true
            end
        elseif lang == "ru" then
            -- Russian: Cyrillic U+0400-U+04FF
            -- UTF-8: bytes 208-209 as first byte
            if byte == 208 or byte == 209 then
                return true
            end
        else
            -- Latin-based languages (en, de, fr, es, pt)
            -- Detect extended ASCII / accented characters (UTF-8 multi-byte)
            -- Any byte >= 128 indicates non-ASCII (potential accented chars)
            if byte >= 192 and byte <= 223 then
                -- 2-byte UTF-8 sequence start (covers Latin Extended, etc.)
                return true
            end
        end
    end
    return false
end

-- Check if text contains characters that need translation based on incoming settings
local function ContainsSourceLanguage(text)
    if not text then return false end
    local sourceLang = WoWTranslateDB and WoWTranslateDB.incomingFromLang or "zh"
    return ContainsLanguageChars(text, sourceLang)
end

-- Check if text contains outgoing target language (to prevent double-translation)
local function ContainsOutgoingTargetLanguage(text)
    if not text then return false end
    local targetLang = WoWTranslateDB and WoWTranslateDB.outgoingToLang or "zh"
    return ContainsLanguageChars(text, targetLang)
end

-- Legacy function name for compatibility
local function ContainsChinese(text)
    return ContainsLanguageChars(text, "zh")
end

-- Pattern-based preprocessing for incoming CJK messages.
-- Converts WoW-CN specific shorthands that the static glossary cannot handle.
local function PreprocessIncoming(text)
    if not text then return text end
    -- Normalize Chinese sentence terminators so bing returns a single translation
    -- segment instead of splitting on sentence boundaries (DLL only reads first segment).
    text = string.gsub(text, "\227\128\130", ". ")   -- 。 U+3002
    text = string.gsub(text, "\239\188\129", "! ")   -- ！ U+FF01
    text = string.gsub(text, "\239\188\159", "? ")   -- ？ U+FF1F
    -- Currency: XG = X gold, XY = X silver. Only when not followed by a letter
    -- so "YY" (Shadowfang Keep), "GM" etc. are not touched.
    -- Run BEFORE 88 handling so "88Y" → "88s" (silver), not "bye Y".
    text = string.gsub(text, "(%d+)G([^%a])", "%1g%2")
    text = string.gsub(text, "(%d+)G$", "%1g")
    text = string.gsub(text, "(%d+)Y([^%a])", "%1s%2")
    text = string.gsub(text, "(%d+)Y$", "%1s")
    -- 110 = patrol mob (China police emergency number used as WoW slang)
    text = string.gsub(text, "([^%w])110([^%w])", "%1巡逻怪%2")
    text = string.gsub(text, "([^%w])110$",        "%1巡逻怪")
    text = string.gsub(text, "^110([^%w])",         "巡逻怪%1")
    text = string.gsub(text, "^110$",               "巡逻怪")
    -- 88 = bye bye (CN internet send-off). Only when isolated (not part of e.g. "880").
    text = string.gsub(text, "([^%w])88([^%w])", "%1再见%2")
    text = string.gsub(text, "([^%w])88$",        "%1再见")
    text = string.gsub(text, "^88([^%w])",         "再见%1")
    text = string.gsub(text, "^88$",               "再见")
    -- 666 = "awesome / well played" (CN superlative slang). Isolated only.
    text = string.gsub(text, "([^%w])666([^%w])", "%1打得好！%2")
    text = string.gsub(text, "([^%w])666$",        "%1打得好！")
    text = string.gsub(text, "^666([^%w])",         "打得好！%1")
    text = string.gsub(text, "^666$",               "打得好！")
    -- 999 = res me (jiǔ = save/rescue, sounds like 9). Isolated only.
    text = string.gsub(text, "([^%w])999([^%w])", "%1救我%2")
    text = string.gsub(text, "([^%w])999$",        "%1救我")
    text = string.gsub(text, "^999([^%w])",         "救我%1")
    text = string.gsub(text, "^999$",               "救我")
    -- 11 = yāo yāo = affirmative / "yes yes". [^%w] boundary; note: may fire on
    -- "我要11个" (I want 11 of them) since CJK chars are not %w in Lua 5.0.
    text = string.gsub(text, "([^%w])11([^%w])", "%1好%2")
    text = string.gsub(text, "([^%w])11$",        "%1好")
    text = string.gsub(text, "^11([^%w])",         "好%1")
    text = string.gsub(text, "^11$",               "好")
    -- 密 (mì, U+5BC6, UTF-8 \229\175\134) = "whisper" in CN WoW slang.
    -- Two context-specific cases that the static glossary cannot cover safely:
    -- compound forms (密我/来密/求密/密密/etc.) are handled by the glossary.
    -- Case 1: entire message is just 密 (optionally with trailing punctuation).
    -- Anchoring to ^ and $ ensures this never fires inside 密码/保密/亲密.
    if string.find(text, "^\229\175\134[%. !?]*$") then
        return "密语"
    end
    -- Case 2: 密 immediately followed by an ASCII player name (e.g. "密 Playerone").
    -- Player names on vanilla servers are ASCII-only [A-Z][a-z]+.
    local _s, _e, pname = string.find(text, "^\229\175\134%s*([%a][%a%d]+)$")
    if pname then
        return "密语 " .. pname
    end
    return text
end

-- Pattern-based preprocessing for outgoing English messages.
-- Converts standard WoW EN currency notation to CN server notation before API.
local function PreprocessOutgoing(text)
    if not text then return text end
    -- Gold: Xg → XG
    text = string.gsub(text, "(%d+)g([^%a])", "%1G%2")
    text = string.gsub(text, "(%d+)g$",        "%1G")
    -- Silver: Xs → XY
    -- With this, "3s CD" or "8s cast time" could wrongly become "3Y CD" but it is a good tradeoff since these are not used often in chat.
    text = string.gsub(text, "(%d+)s([^%a])", "%1Y%2")
    text = string.gsub(text, "(%d+)s$",        "%1Y")
    return text
end

-- Auto-detect which source language a message is in.
-- Returns "zh", "ja", "ko", "ru", or nil if no supported language found.
local function DetectSourceLanguage(text)
    if not text then return nil end
    local enabled = (WoWTranslateDB and WoWTranslateDB.enabledSourceLangs)
                    or { zh=true, ja=true, ko=true, ru=true }
    -- If table exists but every lang is nil/false, fall back to all-enabled
    if not enabled.zh and not enabled.ja and not enabled.ko and not enabled.ru then
        enabled = { zh=true, ja=true, ko=true, ru=true }
    end

    local hasKorean   = false
    local hasHiragana = false
    local hasCJK      = false
    local hasRussian  = false
    local asciiAlpha  = 0

    for i = 1, string.len(text) do
        local b = string.byte(text, i)
        if b >= 234 and b <= 237 then hasKorean = true
        elseif b == 227            then hasHiragana = true
        elseif b >= 228 and b <= 233 then hasCJK = true
        elseif b == 208 or b == 209  then hasRussian = true
        elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            asciiAlpha = asciiAlpha + 1
        end
    end

    if enabled.ko and hasKorean   then return "ko" end
    -- Check zh BEFORE ja: Chinese punctuation (。、「」 etc.) uses UTF-8 byte 0xE3 (227),
    -- the same first byte as Japanese hiragana/katakana. Chinese messages containing
    -- both punctuation (byte 227 → hasHiragana) and characters (bytes 228-233 → hasCJK)
    -- must be treated as Chinese, not Japanese.
    if enabled.zh and hasCJK      then return "zh" end
    if enabled.ja and hasHiragana then return "ja" end
    if enabled.ru and hasRussian  then return "ru" end
    -- English: >= 4 ASCII alpha chars, no CJK/Korean/Japanese/Russian.
    -- Detection is unconditional (same-language skip prevents en→en no-ops).
    if asciiAlpha >= 4 and not (hasCJK or hasKorean or hasHiragana or hasRussian) then
        return "en"
    end
    return nil
end

-- ============================================================================
-- HYPERLINK LOCALIZATION
-- ============================================================================
-- Parse hyperlinks and replace Chinese display names with English equivalents
-- using the client's GetItemInfo() API

-- Queue for messages waiting on item cache
local itemCacheQueue = {}
local itemCacheCounter = 0

-- Hidden tooltip for forcing item cache population
local itemCacheTooltip = CreateFrame("GameTooltip", "WoWTranslateItemCacheTooltip", nil, "GameTooltipTemplate")
itemCacheTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Force item data to be requested from server using SetHyperlink
-- This is more reliable than just calling GetItemInfo()
local function TriggerItemCache(itemId)
    local itemString = "item:" .. itemId .. ":0:0:0"
    itemCacheTooltip:SetHyperlink(itemString)
    DebugLog("触发物品缓存：", itemId)
end

-- Extract all item IDs from a text string
local function ExtractItemIds(text)
    local itemIds = {}
    local pos = 1

    while pos <= string.len(text) do
        -- Look for item links: |Hitem:ITEMID:
        local linkStart = string.find(text, "|Hitem:", pos, true)
        if not linkStart then
            break
        end

        -- Find the item ID (numbers after "item:")
        local idStart = linkStart + 7  -- length of "|Hitem:"
        local idEnd = string.find(text, ":", idStart, true)
        if idEnd then
            local itemIdStr = string.sub(text, idStart, idEnd - 1)
            local itemId = tonumber(itemIdStr)
            DebugLog("提取物品ID：", itemIdStr, "->", itemId or "无效")
            if itemId then
                table.insert(itemIds, itemId)
            end
        end

        pos = linkStart + 1
    end

    DebugLog("提取到物品ID总数：", table.getn(itemIds))
    return itemIds
end

-- Check if all item IDs are cached, trigger cache for uncached ones
-- Returns: allCached (boolean), uncachedIds (table)
local function CheckItemCache(itemIds, triggerCache)
    local uncachedIds = {}

    for _, itemId in ipairs(itemIds) do
        local name, link = GetItemInfo(itemId)
        if not name then
            table.insert(uncachedIds, itemId)
            -- Use SetHyperlink to force server to send item data
            if triggerCache then
                TriggerItemCache(itemId)
            end
        end
    end

    return table.getn(uncachedIds) == 0, uncachedIds
end

-- Parse a hyperlink to extract its components
-- Returns: linkType, linkData, displayText, colorCode (or nils if parse fails)
local function ParseHyperlink(link)
    local colorCode = nil
    local linkType = nil
    local linkData = nil
    local displayText = nil

    -- Check for colored link: |cFFRRGGBB|H...
    local colorStart = string.find(link, "^|c........")
    if colorStart then
        colorCode = string.sub(link, 3, 10)  -- Extract FFRRGGBB
    end

    -- Find |H to start of link data
    local hStart, hEnd = string.find(link, "|H")
    if not hStart then return nil end

    -- Find |h[ to find end of link data and start of display text
    local displayStart, displayStartEnd = string.find(link, "|h%[", hEnd)
    if not displayStart then return nil end

    -- Extract type:data between |H and |h[
    local typeData = string.sub(link, hEnd + 1, displayStart - 1)

    -- Split type:data by first colon
    local colonPos = string.find(typeData, ":")
    if colonPos then
        linkType = string.sub(typeData, 1, colonPos - 1)
        linkData = string.sub(typeData, colonPos + 1)
    else
        linkType = typeData
        linkData = ""
    end

    -- Find ]|h to get display text
    local displayEnd = string.find(link, "%]|h", displayStartEnd)
    if not displayEnd then return nil end

    displayText = string.sub(link, displayStartEnd + 1, displayEnd - 1)

    return linkType, linkData, displayText, colorCode
end

-- Extract item ID from link data (format: itemId:enchantId:suffixId:uniqueId)
local function GetItemIdFromLinkData(linkData)
    local colonPos = string.find(linkData, ":")
    if colonPos then
        return tonumber(string.sub(linkData, 1, colonPos - 1))
    else
        return tonumber(linkData)
    end
end

-- Extract quest ID from link data (format: questId:questLevel)
local function GetQuestIdFromLinkData(linkData)
    local colonPos = string.find(linkData, ":")
    if colonPos then
        return tonumber(string.sub(linkData, 1, colonPos - 1))
    else
        return tonumber(linkData)
    end
end

-- Get English quest name from pfQuest database
-- Returns nil if pfQuest not loaded or quest not found
local function GetEnglishQuestName(questId)
    if not pfDB or not pfDB["quests"] then
        return nil  -- pfQuest未加载
    end

    -- Try custom quests first (more specific)
    local customQuests = pfDB["quests"]["enUS-turtle"]
    if customQuests and customQuests[questId] then
        local entry = customQuests[questId]
        if type(entry) == "table" and entry["T"] then
            return entry["T"]
        end
        -- "_" means deleted, fall through to vanilla
    end

    -- Try vanilla quests
    local vanillaQuests = pfDB["quests"]["enUS"]
    if vanillaQuests and vanillaQuests[questId] then
        local entry = vanillaQuests[questId]
        if type(entry) == "table" and entry["T"] then
            return entry["T"]
        end
    end

    return nil  -- 未找到任务
end

-- Localize a hyperlink by replacing the display text with the English name
-- Currently supports: items (via GetItemInfo)
-- Falls back to original if localization not available
local function LocalizeHyperlink(link)
    DebugLog("开始本地化链接：", string.sub(link, 1, 40))

    local linkType, linkData, displayText, colorCode = ParseHyperlink(link)

    if not linkType then
        DebugLog("  解析失败，返回原始链接")
        return link  -- Couldn't parse, return original
    end

    DebugLog("  解析结果：", linkType, linkData and string.sub(linkData, 1, 20) or "空")

    if linkType == "item" then
        local itemId = GetItemIdFromLinkData(linkData)
        DebugLog("  物品ID：", itemId)
        if itemId then
            -- GetItemInfo returns: name, link, quality, iLevel, ...
            local itemName, itemLink = GetItemInfo(itemId)
            DebugLog("  获取物品信息：", itemName or "空")

            if itemName then
                -- Always rebuild the link manually to ensure correct structure
                -- Use original color code from the Chinese link, just replace the name
                local result
                if colorCode then
                    result = "|c" .. colorCode .. "|H" .. linkType .. ":" .. linkData .. "|h[" .. itemName .. "]|h|r"
                else
                    result = "|H" .. linkType .. ":" .. linkData .. "|h[" .. itemName .. "]|h"
                end
                DebugLog("  已重建英文名称物品链接")
                return result
            else
                -- Item not in client cache yet; trigger a server request so next
                -- occurrence of this item link will resolve to the English name.
                TriggerItemCache(itemId)
            end
        end
    elseif linkType == "quest" then
        local questId = GetQuestIdFromLinkData(linkData)
        DebugLog("  任务ID：", questId)
        if questId then
            local questName = GetEnglishQuestName(questId)
            DebugLog("  获取英文任务名：", questName or "空")

            if questName then
                local result
                if colorCode then
                    result = "|c" .. colorCode .. "|H" .. linkType .. ":" .. linkData .. "|h[" .. questName .. "]|h|r"
                else
                    result = "|H" .. linkType .. ":" .. linkData .. "|h[" .. questName .. "]|h"
                end
                DebugLog("  已重建英文名称任务链接")
                return result
            end
        end
    else
        DebugLog("  非物品/任务链接，跳过本地化")
    end
    -- Quest localization uses pfQuest database (if available)
    -- Spell localization not supported in vanilla WoW 1.12 (no GetSpellInfo API)

    DebugLog("  未找到本地化名称，返回原始链接")
       return link  -- No localized name found, return original
end

-- ============================================================================
-- ROBUST HYPERLINK EXTRACTION
-- ============================================================================
-- WoW 1.12 hyperlink format: |cFFRRGGBB|Htype:data|h[DisplayText]|h|r
-- Key: Extract FULL hyperlinks including color codes as single units

-- Find all hyperlinks in text, returning their positions and content
local function FindAllHyperlinks(text)
    local hyperlinks = {}
    local pos = 1

    while pos <= string.len(text) do
        -- Look for hyperlink start - either |c (colored) or |H (plain)
        local colorStart = string.find(text, "|c........|H", pos)
        local plainStart = string.find(text, "|H", pos)

        local linkStart = nil
        local hasColor = false

        -- Determine which comes first
        if colorStart and (not plainStart or colorStart <= plainStart) then
            linkStart = colorStart
            hasColor = true
        elseif plainStart then
            -- Make sure this |H isn't part of a colored link we already found
            if not colorStart or plainStart < colorStart then
                linkStart = plainStart
                hasColor = false
            end
        end

        if not linkStart then
            break
        end

        -- Find the end of the hyperlink: |h[...]|h followed by optional |r
        -- Pattern: find |h[ then find ]|h
        local displayStart = string.find(text, "|h%[", linkStart)
        if not displayStart then
            pos = linkStart + 1
        else
            -- Find closing ]|h
            local displayEnd = string.find(text, "%]|h", displayStart)
            if not displayEnd then
                pos = linkStart + 1
            else
                local linkEnd = displayEnd + 2  -- Position after ]|h

                -- Check for |r after the link
                if string.sub(text, linkEnd + 1, linkEnd + 2) == "|r" then
                    linkEnd = linkEnd + 2
                end

                -- If we have color, make sure we started from |c
                local actualStart = linkStart
                if hasColor then
                    actualStart = colorStart
                end

                local fullLink = string.sub(text, actualStart, linkEnd)

                DebugLog("找到链接：", string.sub(fullLink, 1, 80))

                table.insert(hyperlinks, {
                    startPos = actualStart,
                    endPos = linkEnd,
                    content = fullLink
                })

                pos = linkEnd + 1
            end
        end
    end

    return hyperlinks
end

-- Split message into segments: text and hyperlinks
-- Returns array of {type="text"|"link", content=string}
local function SplitIntoSegments(text)
    local segments = {}
    local hyperlinks = FindAllHyperlinks(text)

    if table.getn(hyperlinks) == 0 then
        -- No hyperlinks, entire text is translatable
        if text ~= "" then
            table.insert(segments, {type = "text", content = text})
        end
        return segments
    end

    local lastEnd = 0
    for _, link in ipairs(hyperlinks) do
        -- Add text before this hyperlink
        if link.startPos > lastEnd + 1 then
            local textBefore = string.sub(text, lastEnd + 1, link.startPos - 1)
            if textBefore ~= "" then
                table.insert(segments, {type = "text", content = textBefore})
            end
        end

        -- Add the hyperlink (with localized display name if available)
        table.insert(segments, {type = "link", content = LocalizeHyperlink(link.content)})
        lastEnd = link.endPos
    end

    -- Add text after last hyperlink
    if lastEnd < string.len(text) then
        local textAfter = string.sub(text, lastEnd + 1)
        if textAfter ~= "" then
            table.insert(segments, {type = "text", content = textAfter})
        end
    end

    return segments
end

-- Check if any text segments contain source language characters
local function HasTranslatableContent(segments)
    for _, seg in ipairs(segments) do
        if seg.type == "text" and DetectSourceLanguage(seg.content) then
            return true
        end
    end
    return false
end

-- Strip WoW color codes from text before sending to translation API.
-- |cFFRRGGBB...text...|r sequences are not valid UTF-8 markup and confuse bing.
-- The pipe character in translations would also break the requestId|result|error wire format.
local function StripColorCodes(text)
    if not text then return text end
    -- Use "." (any char) instead of %x to avoid any pattern-class compatibility concerns.
    -- WoW color codes are always |c followed by exactly 8 hex characters.
    local result = string.gsub(text, "|c........", "")
    result = string.gsub(result, "|r", "")
    return result
end

-- Split a fully-formatted chat line into header and message body.
-- The header is everything up to and including the first ": " separator
-- (e.g. "|cFF...[PlayerName]|r says: ").  The body is what follows.
-- If no separator is found the header is empty and body is the full text.
local function SplitHeaderAndMessage(text)
    local pos1 = string.find(text, ": ", 1, true)
    local pos2 = string.find(text, "\239\188\154", 1, true) -- UTF-8 fullwidth colon
    local pos3 = string.find(text, "\163\186", 1, true)     -- GBK colon

    local bestPos = nil
    local bestLen = 0
    if pos1 then bestPos = pos1; bestLen = 2 end
    if pos2 and (not bestPos or pos2 < bestPos) then bestPos = pos2; bestLen = 3 end
    if pos3 and (not bestPos or pos3 < bestPos) then bestPos = pos3; bestLen = 2 end

    if not bestPos then
        return "", text
    end

    local header = string.sub(text, 1, bestPos + bestLen - 1)
    local msg    = string.sub(text, bestPos + bestLen)
    return header, msg
end

-- Build text to translate: only text segments, hyperlinks become URL placeholders
-- URLs are preserved by bing Translate because they're recognized as web addresses
local function BuildTranslatableText(segments)
    local parts = {}
    local linkIndex = 0

    for _, seg in ipairs(segments) do
        if seg.type == "text" then
            table.insert(parts, StripColorCodes(seg.content))
        else
            linkIndex = linkIndex + 1
            -- Space-pad the placeholder so bing never merges it with adjacent CJK bytes.
            -- Without spaces, "来人http://ph.wt/1" is treated as one URL and the Chinese
            -- is left untranslated.  The spaces are benign — ReconstructMessage uses a
            -- substring search so it finds "http://ph.wt/N" inside " http://ph.wt/N ".
            table.insert(parts, " http://ph.wt/" .. linkIndex .. " ")
        end
    end

    return table.concat(parts, "")
end

-- Reconstruct message from translated text and original segments
local function ReconstructMessage(segments, translatedText)
    local result = {}
    local workText = translatedText

    -- Count links
    local linkCount = 0
    local linkContents = {}
    for _, seg in ipairs(segments) do
        if seg.type == "link" then
            linkCount = linkCount + 1
            linkContents[linkCount] = seg.content
        end
    end

    if linkCount == 0 then
        return translatedText
    end

    -- Replace each URL placeholder with the original hyperlink
    for i = 1, linkCount do
        local placeholder = "http://ph.wt/" .. i
        -- Also try with https (in case API changes it)
        local placeholder2 = "https://ph.wt/" .. i
        -- Also try URL-encoded or modified versions
        local placeholder3 = "http://ph .wt/" .. i
        local placeholder4 = "http: //ph.wt/" .. i

        local found = false

        DebugLog("链接", i, "内容：", string.sub(linkContents[i] or "nil", 1, 80))

        -- Try exact match first
        local startPos, endPos = string.find(workText, placeholder, 1, true)
        if startPos then
            workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
            found = true
            DebugLog("替换占位符", i)
        end

        -- Try https version
        if not found then
            startPos, endPos = string.find(workText, placeholder2, 1, true)
            if startPos then
                workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
                found = true
                DebugLog("替换HTTPS占位符", i)
            end
        end

        -- Try with space after http:
        if not found then
            startPos, endPos = string.find(workText, placeholder3, 1, true)
            if startPos then
                workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
                found = true
            end
        end

        if not found then
            startPos, endPos = string.find(workText, placeholder4, 1, true)
            if startPos then
                workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
                found = true
            end
        end

        if not found then
            DebugLog("未找到占位符：", placeholder)
            -- Append the link at the end as fallback
            workText = workText .. " " .. linkContents[i]
        end
    end

    return workText
end

-- ============================================================================
-- CHAT FRAME HOOKING
-- ============================================================================

-- Maps event to ChatTypeInfo key so we can read the native channel color.
-- CHAT_MSG_CHANNEL requires special handling (channel slot number determines the key).
local EVENT_TO_CHATTYPE = {
    CHAT_MSG_SAY                 = "SAY",
    CHAT_MSG_YELL                = "YELL",
    CHAT_MSG_WHISPER             = "WHISPER",
    CHAT_MSG_WHISPER_INFORM      = "WHISPER",
    CHAT_MSG_PARTY               = "PARTY",
    CHAT_MSG_GUILD               = "GUILD",
    CHAT_MSG_OFFICER             = "OFFICER",
    CHAT_MSG_RAID                = "RAID",
    CHAT_MSG_RAID_LEADER         = "RAID",
    CHAT_MSG_RAID_WARNING        = "RAID",
    CHAT_MSG_BATTLEGROUND        = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER = "BATTLEGROUND",
    CHAT_MSG_HARDCORE            = "HARDCORE",
}

-- Returns a 6-char uppercase hex string from ChatTypeInfo, or nil if not found.
local function GetChatTypeColorHex(event, channelStr)
    local chatType = EVENT_TO_CHATTYPE[event]
    if not chatType and event == "CHAT_MSG_CHANNEL" then
        local _, _, cap = string.find(channelStr or "", "^(%d+)%.")
        local num = cap and tonumber(cap)
        chatType = num and ("CHANNEL" .. num) or "CHANNEL"
    end
    if chatType and ChatTypeInfo and ChatTypeInfo[chatType] then
        local info = ChatTypeInfo[chatType]
        local r = info.r or 1
        local g = info.g or 1
        local b = info.b or 1
        return string.format("%02X%02X%02X",
            math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5))
    end
    return nil
end

-- Per-event display tags for the [WT-X] prefix shown with each translation.
-- CHAT_MSG_CHANNEL is handled dynamically from arg4 (channel name string).
local EVENT_CHANNEL_TAGS = {
    CHAT_MSG_SAY                  = "翻译-说",
    CHAT_MSG_YELL                 = "翻译-喊",
    CHAT_MSG_WHISPER              = "翻译-密语",
    CHAT_MSG_WHISPER_INFORM       = "翻译-密语",
    CHAT_MSG_PARTY                = "翻译-小队",
    CHAT_MSG_GUILD                = "翻译-公会",
    CHAT_MSG_OFFICER              = "翻译-官员",
    CHAT_MSG_RAID                 = "翻译-团队",
    CHAT_MSG_RAID_LEADER          = "翻译-团队",
    CHAT_MSG_RAID_WARNING         = "翻译-团队",
    CHAT_MSG_BATTLEGROUND         = "翻译-战场",
    CHAT_MSG_BATTLEGROUND_LEADER  = "翻译-战场",
    CHAT_MSG_HARDCORE             = "翻译-硬核",
}

-- Returns the [WT-X] tag string for a given event.
-- For CHAT_MSG_CHANNEL, channelStr is arg4 (e.g. "2. Trade" or "World").
local function GetChannelTag(event, channelStr)
    local tag = EVENT_CHANNEL_TAGS[event]
    if tag then return tag end
    if event == "CHAT_MSG_CHANNEL" then
        if channelStr and channelStr ~= "" then
            -- Strip leading "N. " number prefix that WoW prepends to channel names
            local name = string.gsub(channelStr, "^%d+%.%s*", "")
            if name and name ~= "" then return "翻译-" .. name end
        end
        return "翻译-频道"
    end
    return "翻译"
end

-- ============================================================================
-- PLAYER NAME TRANSLATION
-- ============================================================================
local NAME_CACHE_PREFIX = "\1wt_name:"

local function NameCacheKey(name)
    return NAME_CACHE_PREFIX .. name
end

local function ShouldTranslatePlayerName(name)
    if not name or name == "" then return false end
    local lang = DetectSourceLanguage(name)
    if not lang then return false end
    local target = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
    return lang ~= target
end

local TRANSLATED_NAME_MARK = "|cFFFFFF00*|r"

local function RgbHex(colorOrR, g, b, a)
    local r, gr, bl, al
    if type(colorOrR) == "table" then
        if colorOrR.r then r, gr, bl, al = colorOrR.r, colorOrR.g, colorOrR.b, (colorOrR.a or 1) end
    elseif tonumber(colorOrR) then
        r, gr, bl, al = colorOrR, g, b, (a or 1)
    end
    if not r then return "" end
    if r > 1 then r = 1 elseif r < 0 then r = 0 end
    if gr > 1 then gr = 1 elseif gr < 0 then gr = 0 end
    if bl > 1 then bl = 1 elseif bl < 0 then bl = 0 end
    if al > 1 then al = 1 elseif al < 0 then al = 0 end
    return string.format("|c%02x%02x%02x%02x", al*255, r*255, gr*255, bl*255)
end

local function ApplyNameCapitalization(name)
    if not name or name == "" then return name end
    if type(CapitalizeName) == "function" then return CapitalizeName(name) end
    local parts = {}
    for word in string.gfind(name, "%S+") do
        if string.len(word) > 0 then
            table.insert(parts, string.upper(string.sub(word,1,1)) .. string.lower(string.sub(word,2)))
        end
    end
    if table.getn(parts) == 0 then return name end
    return table.concat(parts, " ")
end

local function FindPlayerUnitByName(name)
    if not name or name == "" then return nil end
    local function matchUnit(unit)
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local un = UnitName(unit)
            local pvp = UnitPVPName(unit)
            if un == name or (pvp and pvp == name) then return unit end
        end
    end
    local unit = matchUnit("mouseover")
    if unit then return unit end
    unit = matchUnit("target")
    if unit then return unit end
    unit = matchUnit("player")
    if unit then return unit end
    for i = 1, 4 do
        unit = matchUnit("party" .. i)
        if unit then return unit end
    end
    for i = 1, 40 do
        unit = matchUnit("raid" .. i)
        if unit then return unit end
    end
    return nil
end

local function ResolvePlayerClass(rawName, unit)
    if unit and UnitExists(unit) and UnitIsPlayer(unit) then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    unit = FindPlayerUnitByName(rawName)
    if unit then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    return nil
end

local function MarkTranslatedDisplayName(rawName, displayName, unit)
    if not displayName or displayName == "" then return displayName end
    if not rawName or displayName == rawName then return displayName end
    local plain = StripColorCodes(displayName)
    plain = ApplyNameCapitalization(plain)
    local class = ResolvePlayerClass(rawName, unit)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        return RgbHex(RAID_CLASS_COLORS[class]) .. plain .. "|r" .. TRANSLATED_NAME_MARK
    end
    return plain .. TRANSLATED_NAME_MARK
end

-- Build [Name*] <Guild*>: prefix for [WT] chat lines.
-- When translatePlayerNames is off, resolvedName == rawName so MarkTranslatedDisplayName
-- returns rawName with no *, giving the same output as the old static senderPrefix.
local function BuildSenderPrefix(rawName, resolvedName, channel, guildDisplay)
    if not rawName or rawName == "" then return "" end
    local unit = FindPlayerUnitByName(rawName)
    local resolved = resolvedName or rawName
    local isTranslated = resolved ~= rawName
    local guildStr = ""
    if guildDisplay and guildDisplay ~= "" then
        guildStr = " <" .. guildDisplay .. "*>"
    end
    if channel then
        if isTranslated then
            -- ShaguTweaks chat-levels/social-colors pattern requires [rawName]
            -- in the display to match, which breaks when we replace it. Instead,
            -- build class color and level ourselves: read level from ShaguTweaks'
            -- player cache (ShaguTweaks_cache.players[name].level) with UnitLevel
            -- as fallback, and apply difficulty color via GetDifficultyColor.
            local plain = ApplyNameCapitalization(StripColorCodes(resolved))
            -- Mirror social-colors.lua: use ShaguTweaks.GetUnitData for the class lookup
            -- since it has the same broad reach (unit frames + ShaguTweaks player cache)
            -- that lets social-colors color the raw name. Fall back to ResolvePlayerClass.
            local classColor = nil
            if ShaguTweaks and type(ShaguTweaks.GetUnitData) == "function" then
                local class = ShaguTweaks.GetUnitData(rawName)
                if class and class ~= UNKNOWN then
                    classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
                end
            end
            if not classColor then
                local class = ResolvePlayerClass(rawName, unit)
                classColor = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            end
            local coloredName = classColor and (RgbHex(classColor) .. plain .. "|r") or plain
            local levelStr = ""
            local shaguData = ShaguTweaks_cache and ShaguTweaks_cache["players"] and ShaguTweaks_cache["players"][rawName]
            local lvl = shaguData and shaguData.level
            if (not lvl or lvl <= 0) and unit then lvl = UnitLevel(unit) end
            if lvl and lvl > 0 then
                local dr, dg, db = GetDifficultyColor(lvl)
                levelStr = " " .. RgbHex(dr, dg, db) .. tostring(lvl) .. "|r"
            end
            return "|Hplayer:" .. rawName .. "|h[" .. coloredName .. "]|h|r"
                .. TRANSLATED_NAME_MARK .. levelStr .. guildStr .. ": "
        else
            return "|Hplayer:" .. rawName .. "|h[" .. rawName .. "]|h|r" .. guildStr .. ": "
        end
    else
        local nameStr = MarkTranslatedDisplayName(rawName, resolved, unit)
        return nameStr .. guildStr .. ": "
    end
end

local function ResolvePlayerDisplayName(rawName, callback)
    if not callback then return end
    if not WoWTranslateDB or not WoWTranslateDB.translatePlayerNames then
        callback(rawName)
        return
    end
    if not rawName or rawName == "" then
        callback(rawName)
        return
    end
    if not ShouldTranslatePlayerName(rawName) then
        callback(rawName)
        return
    end
    local cacheKey = NameCacheKey(rawName)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then callback(cached); return end

    local nameLang = DetectSourceLanguage(rawName)
    if not nameLang then callback(rawName); return end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(rawName)
        return
    end

    local waiters = pendingNameTranslations[rawName]
    if waiters then
        table.insert(waiters.callbacks, callback)
        return
    end

    waiters = { callbacks = { callback } }
    pendingNameTranslations[rawName] = waiters

    local function finish(result)
        local w = pendingNameTranslations[rawName]
        pendingNameTranslations[rawName] = nil
        if w then
            for i = 1, table.getn(w.callbacks) do w.callbacks[i](result) end
        end
    end

    local ok = WoWTranslate_API.Translate(rawName, function(translation, err)
        if translation and translation ~= "" then
            local capitalized = ApplyNameCapitalization(translation)
            WoWTranslate_CacheSave(cacheKey, capitalized)
            finish(capitalized)
        else
            finish(rawName)
        end
    end, nameLang)

    if not ok then
        -- Queue full; poll cache briefly so the waiter doesn't hang.
        local retries = 0
        local pollFrame = CreateFrame("Frame")
        local elapsed = 0
        pollFrame:SetScript("OnUpdate", function()
            elapsed = elapsed + arg1
            if elapsed < 0.1 then return end
            elapsed = 0
            retries = retries + 1
            local c, hit = WoWTranslate_CacheGet(cacheKey)
            if hit then
                pollFrame:SetScript("OnUpdate", nil)
                finish(c)
            elseif retries >= 50 then
                pollFrame:SetScript("OnUpdate", nil)
                finish(rawName)
            end
        end)
    end
end

-- ============================================================================
-- MANUAL SINGLE-LINE TRANSLATION
-- ============================================================================
local function EnsureManualTranslateStore()
    if type(WoWTranslateManualRecords) ~= "table" then
        WoWTranslateManualRecords = {}
    end
    if type(WoWTranslateManualRecords.records) ~= "table" then
        WoWTranslateManualRecords.records = {}
    end
    if type(WoWTranslateManualRecords.order) ~= "table" then
        WoWTranslateManualRecords.order = {}
    end
    WoWTranslateManualRecords.lastId = tonumber(WoWTranslateManualRecords.lastId) or 0
end

local function TrimManualTranslateStore()
    EnsureManualTranslateStore()
    while table.getn(WoWTranslateManualRecords.order) > MANUAL_TRANSLATE_MAX_RECORDS do
        local oldId = table.remove(WoWTranslateManualRecords.order, 1)
        if oldId then
            WoWTranslateManualRecords.records[tostring(oldId)] = nil
            manualTranslateFrames[tostring(oldId)] = nil
        end
    end
end

local function BuildManualTranslateLink(id)
    return "|cFF00FFFF|Hwtmsg:" .. tostring(id) .. "|h[译]|h|r"
end

local function ShouldRecordManualMessage(eventName, rawText, sender)
    if not WoWTranslateDB or not WoWTranslateDB.manualTranslateEnabled then return false end
    if not WoWTranslateDB.manualTranslateShowLinks then return false end
    if not EVENT_TO_CHANNEL[eventName] then return false end
    if not rawText or rawText == "" then return false end
    if string.sub(rawText, 1, 1) == "#" then return false end
    if not sender or sender == "" then return false end

    local detectedLang = DetectSourceLanguage(rawText)
    if not detectedLang then return false end
    if detectedLang == "zh" then return false end

    return true
end

local function StoreManualTranslateRecord(frame, eventName, rawText, sender, channelStr)
    if not ShouldRecordManualMessage(eventName, rawText, sender) then return nil end
    EnsureManualTranslateStore()
    WoWTranslateManualRecords.lastId = WoWTranslateManualRecords.lastId + 1
    local id = tostring(WoWTranslateManualRecords.lastId)
    local frameName = frame and frame.GetName and frame:GetName() or nil
    WoWTranslateManualRecords.records[id] = {
        text = rawText,
        sender = sender,
        event = eventName,
        channelStr = channelStr,
        frameName = frameName,
        timestamp = GetTime(),
    }
    table.insert(WoWTranslateManualRecords.order, id)
    manualTranslateFrames[id] = frame
    TrimManualTranslateStore()
    return id
end

local function AppendManualTranslateLink(displayText, id)
    if not id or type(displayText) ~= "string" or displayText == "" then return displayText end
    return displayText .. " " .. BuildManualTranslateLink(id)
end

local function PostManualTranslation(record, translatedBody, frame)
    if not frame then frame = DEFAULT_CHAT_FRAME end
    local channel = EVENT_TO_CHANNEL[record.event]
    local channelTag = GetChannelTag(record.event, record.channelStr)
    local msgColor = (WoWTranslateDB and WoWTranslateDB.translationColor) or ""
    local chanColorHex = GetChatTypeColorHex(record.event, record.channelStr)
    local chanNamePart = string.sub(channelTag, 1, 3) == "WT-" and string.sub(channelTag, 4) or nil

    ResolvePlayerDisplayName(record.sender, function(displayName)
        local prefix
        if chanColorHex and chanNamePart then
            prefix = "|cFF00FFFF[WT-|r|cFF" .. chanColorHex .. chanNamePart .. "]|r"
        else
            prefix = "|cFF00FFFF[" .. channelTag .. "]|r"
        end
        local bodyHex = msgColor
        if WoWTranslateDB and WoWTranslateDB.translationColorFollow then
            bodyHex = chanColorHex or ""
        end
        local displayBody = bodyHex ~= "" and ("|cFF" .. bodyHex .. translatedBody .. "|r") or translatedBody
        local senderPrefix = BuildSenderPrefix(record.sender, displayName, channel, nil)
        frame:AddMessage(prefix .. " " .. senderPrefix .. displayBody)
    end)
end

local function TranslateManualMessageById(id, frame)
    EnsureManualTranslateStore()
    id = tostring(id or "")
    local record = WoWTranslateManualRecords.records[id]
    if not record then
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 这条聊天记录已超过500条缓存上限或已失效|r")
        return
    end

    local rawText = record.text
    local detectedLang = DetectSourceLanguage(rawText)
    if not detectedLang then
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 这条消息没有检测到可翻译语言|r")
        return
    end
    local targetLang = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
    if detectedLang == targetLang then
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 这条消息已经是目标语言|r")
        return
    end

    local segments = SplitIntoSegments(rawText)
    if not HasTranslatableContent(segments) then
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 这条消息没有可翻译的正文|r")
        return
    end

    local cached, found = WoWTranslate_CacheGet(rawText)
    if found then
        PostManualTranslation(record, ReconstructMessage(segments, cached), frame)
        return
    end

    local plainText = BuildTranslatableText(segments)
    local textToTranslate = plainText
    if detectedLang == "en" then
        if WoWTranslate_CheckOutGlossaryExact then
            local outExact = WoWTranslate_CheckOutGlossaryExact(plainText)
            if outExact then
                WoWTranslate_CacheSave(rawText, outExact)
                PostManualTranslation(record, ReconstructMessage(segments, outExact), frame)
                return
            end
        end
        if WoWTranslate_CheckOutGlossaryPartial then
            local outPartial = WoWTranslate_CheckOutGlossaryPartial(plainText)
            if outPartial then textToTranslate = outPartial end
        end
    else
        plainText = PreprocessIncoming(plainText)
        textToTranslate = plainText
        local glossaryResult = WoWTranslate_CheckGlossaryExact(plainText)
        if glossaryResult then
            WoWTranslate_CacheSave(rawText, glossaryResult)
            PostManualTranslation(record, ReconstructMessage(segments, glossaryResult), frame)
            return
        end
        local partialResult = WoWTranslate_CheckGlossaryPartial(plainText)
        if partialResult then
            if not DetectSourceLanguage(partialResult) then
                WoWTranslate_CacheSave(rawText, partialResult)
                PostManualTranslation(record, ReconstructMessage(segments, partialResult), frame)
                return
            end
            textToTranslate = partialResult
        end
    end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 翻译核心未加载 - 输入 /wt status 查看|r")
        return
    end

    local ok = WoWTranslate_API.Translate(textToTranslate, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(rawText, translation)
            PostManualTranslation(record, ReconstructMessage(segments, translation), frame)
        else
            (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 单条翻译失败 (" .. tostring(err) .. ")|r")
        end
    end, detectedLang)

    if not ok then
        (frame or DEFAULT_CHAT_FRAME):AddMessage("|cFFFFFF00[WT]: 翻译队列正忙，请稍后再点一次[译]|r")
    end
end

-- callback(guildDisplay, rankDisplay, rawGuild):
--   guildDisplay = translated guild name, nil if not translatable
--   rankDisplay  = translated rank name,  nil if not translatable
--   rawGuild     = raw guild name always (so caller can show it alongside a translated rank)
-- tooltipGuildText: the guild name read directly from the <GuildName> tooltip line,
--   used to detect servers that return GetGuildInfo as (rank, guild) instead of (guild, rank).
local function ResolveGuildDisplayName(rawName, tooltipGuildText, callback)
    if not WoWTranslateDB or not WoWTranslateDB.translateGuildNames then
        callback(nil, nil, nil)
        return
    end
    local unit = FindPlayerUnitByName(rawName)
    if not unit then callback(nil, nil, nil); return end
    local ret1, ret2 = GetGuildInfo(unit)
    if not ret1 or ret1 == "" then callback(nil, nil, nil); return end

    -- Detect and correct servers where GetGuildInfo returns (rankName, guildName) instead of
    -- the standard (guildName, rankName).  The tooltip <GuildName> line is authoritative.
    local guildName, guildRankName = ret1, ret2 or ""
    if tooltipGuildText and tooltipGuildText ~= "" and ret2 and ret2 ~= "" then
        if ret2 == tooltipGuildText and ret1 ~= tooltipGuildText then
            guildName, guildRankName = ret2, ret1
        end
    end

    local function hasTranslatable(s)
        return s and (ContainsLanguageChars(s,"zh") or ContainsLanguageChars(s,"ja")
            or ContainsLanguageChars(s,"ko") or ContainsLanguageChars(s,"ru"))
    end

    -- guildName is always passed as rawGuild so callers can show it untranslated when needed.
    local function resolveRank(guildDisplay)
        if not hasTranslatable(guildRankName) then callback(guildDisplay, nil, guildName); return end
        local rankCacheKey = NameCacheKey("rank:" .. guildRankName)
        local rankCached, rankFound = WoWTranslate_CacheGet(rankCacheKey)
        if rankFound then callback(guildDisplay, rankCached, guildName); return end
        if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
            callback(guildDisplay, nil, guildName); return
        end
        local rLang = DetectSourceLanguage(guildRankName)
        if not rLang then callback(guildDisplay, nil, guildName); return end
        local ok = WoWTranslate_API.Translate(guildRankName, function(translation, err)
            if translation and translation ~= "" then
                WoWTranslate_CacheSave(rankCacheKey, translation)
                callback(guildDisplay, translation, guildName)
            else
                callback(guildDisplay, nil, guildName)
            end
        end, rLang)
        if not ok then callback(guildDisplay, nil, guildName) end
    end

    if not hasTranslatable(guildName) then resolveRank(nil); return end

    local cacheKey = NameCacheKey("guild:" .. guildName)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then resolveRank(cached); return end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(nil, nil, guildName); return
    end
    local gLang = DetectSourceLanguage(guildName)
    if not gLang then resolveRank(nil); return end

    local ok = WoWTranslate_API.Translate(guildName, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(cacheKey, translation)
            resolveRank(translation)
        else
            resolveRank(nil)
        end
    end, gLang)
    if not ok then callback(nil, nil, guildName) end
end

-- Global entry point for guild-name-only translation (used by OOC nameplate guild display).
-- callback(displayGuild) — displayGuild is nil when not translatable or queue full.
function WoWTranslate_ResolveGuildDisplayName(rawGuild, callback)
    if not rawGuild or rawGuild == "" then callback(nil); return end
    local function hasTranslatable(s)
        return s and (ContainsLanguageChars(s,"zh") or ContainsLanguageChars(s,"ja")
            or ContainsLanguageChars(s,"ko") or ContainsLanguageChars(s,"ru"))
    end
    if not hasTranslatable(rawGuild) then callback(nil); return end
    local cacheKey = NameCacheKey("guild:" .. rawGuild)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then callback(cached); return end
    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(nil); return
    end
    local gLang = DetectSourceLanguage(rawGuild)
    if not gLang then callback(nil); return end
    local ok = WoWTranslate_API.Translate(rawGuild, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(cacheKey, translation)
            callback(translation)
        else
            callback(nil)
        end
    end, gLang)
    if not ok then callback(nil) end
end

function WoWTranslate_SetTranslateNameplates(val)
    if WoWTranslateDB then WoWTranslateDB.translateNameplates = val end
    if val and wtNameplateScanStart then wtNameplateScanStart() end
end

function WoWTranslate_SetTranslatePlayerNames(val)
    if WoWTranslateDB then WoWTranslateDB.translatePlayerNames = val end
end

function WoWTranslate_SetTranslateGuildNames(val)
    if WoWTranslateDB then WoWTranslateDB.translateGuildNames = val end
end

-- ============================================================================
-- TOOLTIP NAME TRANSLATION
-- ============================================================================
local wtTooltipFrame = nil
local TOOLTIP_MAX_LINES = 30

local function TooltipIsShown(tooltip)
    if not tooltip or not tooltip.IsShown then return false end
    local shown = tooltip:IsShown()
    return shown == 1 or shown == true
end

local function CaptureTooltipStatusBarState(tooltip)
    if tooltip ~= GameTooltip then return end
    local bar = GameTooltipStatusBar
    if not bar then return end
    local shown = bar:IsShown()
    tooltip.wtStatusBarWasVisible = (shown == 1 or shown == true)
end

local function RestoreTooltipStatusBar(tooltip)
    if tooltip ~= GameTooltip or not tooltip.wtStatusBarWasVisible then return end
    if not TooltipIsShown(tooltip) then return end
    local bar = GameTooltipStatusBar
    if not bar then return end
    local unit = tooltip.wtUnit
    if (not unit or not UnitExists(unit)) and UnitExists("mouseover") then unit = "mouseover" end
    if not unit or not UnitExists(unit) then return end
    local healthMax = UnitHealthMax(unit)
    if not healthMax or healthMax <= 0 then return end
    bar:SetMinMaxValues(0, healthMax)
    bar:SetValue(UnitHealth(unit))
    bar:Show()
    if bar.bg and bar.bg.Show then bar.bg:Show() end
    if bar.backdrop and bar.backdrop.Show then bar.backdrop:Show() end
    if WoWTranslate_OnTooltipLayoutRefresh then WoWTranslate_OnTooltipLayoutRefresh(tooltip, unit) end
end

local function GetTooltipTextFont(tooltip, lineIndex)
    lineIndex = lineIndex or 1
    if tooltip == GameTooltip then return getglobal("GameTooltipTextLeft" .. lineIndex) end
    if ItemRefTooltip and tooltip == ItemRefTooltip then
        return getglobal("ItemRefTooltipTextLeft" .. lineIndex)
    end
    if tooltip and tooltip.GetName then return getglobal(tooltip:GetName() .. "TextLeft" .. lineIndex) end
end

local function GetTooltipLinePair(tooltip, lineIndex)
    local tipName = tooltip and tooltip.GetName and tooltip:GetName()
    if not tipName then return nil, nil end
    return getglobal(tipName .. "TextLeft" .. lineIndex),
           getglobal(tipName .. "TextRight" .. lineIndex)
end

local function CaptureTooltipLine(left, right)
    local entry = { leftText="", rightText="", leftShown=false, rightShown=false }
    if left then
        entry.leftText = left:GetText() or ""
        entry.leftR, entry.leftG, entry.leftB = left:GetTextColor()
        entry.leftShown = entry.leftText ~= ""
    end
    if right then
        entry.rightText = right:GetText() or ""
        entry.rightR, entry.rightG, entry.rightB = right:GetTextColor()
        entry.rightShown = entry.rightText ~= ""
    end
    return entry
end

local function ClearTooltipLine(left, right)
    if left and left.Hide then left:SetText(""); left:Hide() end
    if right and right.Hide then right:SetText(""); right:Hide() end
end

local function SnapshotTooltipLines(tooltip)
    local numLines = 1
    if tooltip.NumLines then
        numLines = tooltip:NumLines()
        if numLines < 1 then numLines = 1 end
    end
    local snap = { numLines = numLines, lines = {} }
    for i = 1, numLines do
        local left, right = GetTooltipLinePair(tooltip, i)
        snap.lines[i] = CaptureTooltipLine(left, right)
    end
    return snap
end

local function WipeTooltipTextLines(tooltip)
    local tipName = tooltip and tooltip.GetName and tooltip:GetName()
    if not tipName then return end
    for i = 1, TOOLTIP_MAX_LINES do
        ClearTooltipLine(getglobal(tipName.."TextLeft"..i), getglobal(tipName.."TextRight"..i))
    end
end

local function ClearTooltipNameHeader(tooltip)
    if not tooltip then return end
    if wtTooltipFrame and wtTooltipFrame.watchTooltip == tooltip then
        wtTooltipFrame.watchTooltip = nil
        wtTooltipFrame:SetScript("OnUpdate", nil)
    end
    if tooltip.ClearLines then tooltip:ClearLines() end
    WipeTooltipTextLines(tooltip)
    tooltip.wtLineSnapshot = nil
    tooltip.wtLine1Text = nil
    tooltip.wtAddedNameLine = nil
    tooltip.wtWtInternalAddLine = nil
    tooltip.wtNameResolvePending = nil
    tooltip.wtStatusBarWasVisible = nil
end

local function ReplayTooltipLine(tooltip, entry)
    if not entry then return end
    local hasLeft  = entry.leftShown  and entry.leftText  and entry.leftText  ~= ""
    local hasRight = entry.rightShown and entry.rightText and entry.rightText ~= ""
    if hasRight and tooltip.AddDoubleLine then
        tooltip:AddDoubleLine(
            hasLeft and entry.leftText or "", entry.rightText,
            entry.leftR or 1, entry.leftG or 1, entry.leftB or 1,
            entry.rightR or 1, entry.rightG or 1, entry.rightB or 1)
    elseif hasLeft and tooltip.AddLine then
        tooltip:AddLine(entry.leftText, entry.leftR or 1, entry.leftG or 1, entry.leftB or 1)
    elseif hasRight and tooltip.AddLine then
        tooltip:AddLine(entry.rightText, entry.rightR or 1, entry.rightG or 1, entry.rightB or 1)
    end
end

-- Fallback for tooltips without ClearLines/AddLine: prepend only the first line.
local function InsertTooltipNamePrepend(tooltip, text)
    local left1 = GetTooltipTextFont(tooltip, 1)
    if not left1 then return end
    local orig = left1:GetText() or ""
    if tooltip.wtLine1Text then return end
    tooltip.wtLine1Text = orig
    CaptureTooltipStatusBarState(tooltip)
    left1:SetText(text .. "|n" .. orig)
    tooltip.wtAddedNameLine = true
    tooltip:Show()
    RestoreTooltipStatusBar(tooltip)
end

-- Rebuild tooltip with translated lines prepended; original lines follow.
local function InsertTooltipLines(tooltip, lines)
    if not tooltip or tooltip.wtAddedNameLine then return end
    if not lines or table.getn(lines) == 0 then return end
    if not TooltipIsShown(tooltip) then return end
    if not tooltip.ClearLines or not tooltip.AddLine then
        InsertTooltipNamePrepend(tooltip, lines[1])
        return
    end
    tooltip.wtLineSnapshot = SnapshotTooltipLines(tooltip)
    CaptureTooltipStatusBarState(tooltip)
    tooltip.wtWtInternalAddLine = true
    tooltip:ClearLines()
    for i = 1, table.getn(lines) do
        tooltip:AddLine(lines[i], 1, 1, 1)
    end
    for i = 1, tooltip.wtLineSnapshot.numLines do
        ReplayTooltipLine(tooltip, tooltip.wtLineSnapshot.lines[i])
    end
    tooltip.wtWtInternalAddLine = nil
    local numLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    for i = numLines + 1, TOOLTIP_MAX_LINES do
        ClearTooltipLine(GetTooltipLinePair(tooltip, i))
    end
    tooltip.wtAddedNameLine = true
    tooltip:Show()
    RestoreTooltipStatusBar(tooltip)
end

local function ArmTooltipLayoutWatch(tooltip)
    if not wtTooltipFrame or not tooltip then return end
    wtTooltipFrame.watchTooltip = tooltip
    wtTooltipFrame.watchLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    wtTooltipFrame.watchElapsed = 0
    wtTooltipFrame.layoutDelay = 0
    wtTooltipFrame.layoutPending = true
    wtTooltipFrame:SetScript("OnUpdate", function()
        local tip = wtTooltipFrame.watchTooltip
        if not tip or not TooltipIsShown(tip) or not tip.wtAddedNameLine then
            wtTooltipFrame.watchTooltip = nil
            wtTooltipFrame:SetScript("OnUpdate", nil)
            return
        end
        wtTooltipFrame.watchElapsed = wtTooltipFrame.watchElapsed + arg1
        local n = (tip.NumLines and tip:NumLines()) or 0
        if n ~= wtTooltipFrame.watchLines then
            wtTooltipFrame.watchLines = n
            wtTooltipFrame.layoutDelay = 0
            wtTooltipFrame.layoutPending = true
        elseif wtTooltipFrame.layoutPending then
            wtTooltipFrame.layoutDelay = wtTooltipFrame.layoutDelay + arg1
            if wtTooltipFrame.layoutDelay >= 0.12 then
                tip:Show()
                RestoreTooltipStatusBar(tip)
                wtTooltipFrame.layoutPending = nil
                wtTooltipFrame.layoutDelay = 0
            end
        end
        if wtTooltipFrame.watchElapsed >= 1.0 then
            wtTooltipFrame.watchTooltip = nil
            wtTooltipFrame:SetScript("OnUpdate", nil)
        end
    end)
end

local function ParsePlayerHyperlink(link)
    if not link then return nil end
    if string.sub(link, 1, 7) ~= "player:" then return nil end
    local name = string.sub(link, 8)
    if name and name ~= "" then return name end
    return nil
end

local function FindPlayerUnitFromTooltipText(tipText)
    if not tipText or tipText == "" then return nil end
    local plain = StripColorCodes(tipText)
    local function matchUnit(unit)
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local name = UnitName(unit)
            local pvp  = UnitPVPName(unit)
            if name and (string.find(plain, name, 1, true) or (pvp and string.find(plain, pvp, 1, true))) then
                return unit, name, pvp
            end
        end
    end
    local unit, name, pvp = matchUnit("mouseover")
    if unit then return unit, name, pvp end
    unit, name, pvp = matchUnit("target")
    if unit then return unit, name, pvp end
    unit, name, pvp = matchUnit("player")
    if unit then return unit, name, pvp end
    for i = 1, 4 do unit, name, pvp = matchUnit("party"..i); if unit then return unit, name, pvp end end
    for i = 1, 40 do unit, name, pvp = matchUnit("raid"..i); if unit then return unit, name, pvp end end
    return nil
end

local function ResolveTooltipPlayerName(tooltip)
    if tooltip.wtPlayerName and tooltip.wtPlayerName ~= "" then
        local altName = nil
        if tooltip.wtUnit and UnitExists(tooltip.wtUnit) then altName = UnitPVPName(tooltip.wtUnit) end
        return tooltip.wtPlayerName, altName
    end
    if tooltip.wtUnit and UnitExists(tooltip.wtUnit) and UnitIsPlayer(tooltip.wtUnit) then
        local name = UnitName(tooltip.wtUnit)
        local pvp  = UnitPVPName(tooltip.wtUnit)
        if name and name ~= "" then tooltip.wtPlayerName = name; return name, pvp end
    end
    local fs = GetTooltipTextFont(tooltip, 1)
    if fs and fs.GetText then
        local tipText = fs:GetText()
        local unit, name, pvp = FindPlayerUnitFromTooltipText(tipText)
        if name then tooltip.wtUnit = unit; tooltip.wtPlayerName = name; return name, pvp end
        local plain = StripColorCodes(tipText)
        if plain and plain ~= "" and ShouldTranslatePlayerName(plain) then
            tooltip.wtPlayerName = plain; return plain, nil
        end
    end
    return nil
end

local function UpdateTooltipPlayerNames(tooltip)
    if not tooltip then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
    local doName  = WoWTranslateDB.translatePlayerNames
    local doGuild = WoWTranslateDB.translateGuildNames
    if not doName and not doGuild then return end
    if not TooltipIsShown(tooltip) then return end
    if tooltip.wtAddedNameLine then return end

    local rawName = ResolveTooltipPlayerName(tooltip)
    if not rawName or rawName == "" then return end
    -- Allow English-named players through when guild translation is enabled;
    -- ResolveGuildDisplayName will decide whether their guild/rank needs translation.
    if not ShouldTranslatePlayerName(rawName) and not doGuild then return end

    if tooltip.wtNameResolvePending == rawName then return end
    tooltip.wtNameResolvePending = rawName

    ResolvePlayerDisplayName(rawName, function(displayName)
        tooltip.wtNameResolvePending = nil
        if not TooltipIsShown(tooltip) then return end
        if tooltip.wtPlayerName ~= rawName then return end
        if tooltip.wtAddedNameLine then return end

        -- Synchronously read the tooltip guild line before any async call:
        -- captures guild color for display and the authoritative guild text
        -- for swap-detection inside ResolveGuildDisplayName.
        local guildR, guildG, guildB
        local tooltipGuildText = ""
        local tipName = tooltip:GetName()
        if tipName then
            local numLines = (tooltip.NumLines and tooltip:NumLines()) or 0
            for i = 2, numLines do
                local left = getglobal(tipName .. "TextLeft" .. i)
                if left then
                    local t = left:GetText() or ""
                    if string.find(t, "^<") then
                        guildR, guildG, guildB = left:GetTextColor()
                        tooltipGuildText = string.sub(t, 2, string.len(t) - 1)
                        break
                    end
                end
            end
        end

        ResolveGuildDisplayName(rawName, tooltipGuildText, function(guildDisplay, rankDisplay, rawGuild)
            if not TooltipIsShown(tooltip) then return end
            if tooltip.wtAddedNameLine then return end

            local lines = {}
            local marked = MarkTranslatedDisplayName(rawName, displayName, tooltip.wtUnit)

            local hasGuild = guildDisplay and guildDisplay ~= ""
            local hasRank  = rankDisplay  and rankDisplay  ~= ""
            -- Show raw guild (no *) alongside a translated rank when the guild itself
            -- needs no translation.
            local showRawGuild = (not hasGuild) and hasRank and rawGuild and rawGuild ~= ""

            if marked and marked ~= rawName then
                table.insert(lines, marked)
            elseif (hasGuild or hasRank) and rawName and rawName ~= "" then
                -- English name: passthrough with class color so it appears above guild/rank
                local class = ResolvePlayerClass(rawName, tooltip.wtUnit)
                local nameOut = rawName
                if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
                    nameOut = RgbHex(RAID_CLASS_COLORS[class]) .. rawName .. "|r"
                end
                table.insert(lines, nameOut)
            end

            if hasGuild or hasRank then
                local gColor = guildR and RgbHex(guildR, guildG, guildB) or ""
                local rColor = "|cFFAAAAAA"  -- light grey matching OG rank appearance

                local guildLine = ""
                if hasGuild then
                    -- Echo check: bing Translate sometimes returns source text unchanged
                    local guildTranslated = rawGuild and (guildDisplay ~= rawGuild)
                    if guildTranslated then
                        if gColor ~= "" then
                            guildLine = gColor .. "<" .. guildDisplay .. "|r" .. TRANSLATED_NAME_MARK .. gColor .. ">|r"
                        else
                            guildLine = "<" .. guildDisplay .. TRANSLATED_NAME_MARK .. ">"
                        end
                    else
                        -- Translation echoed source (or rawGuild unknown): show without mark
                        if gColor ~= "" then
                            guildLine = gColor .. "<" .. guildDisplay .. ">|r"
                        else
                            guildLine = "<" .. guildDisplay .. ">"
                        end
                    end
                elseif showRawGuild then
                    -- Untranslated guild shown for context beside a translated rank; no *
                    if gColor ~= "" then
                        guildLine = gColor .. "<" .. rawGuild .. ">|r"
                    else
                        guildLine = "<" .. rawGuild .. ">"
                    end
                end
                if hasRank then
                    -- (Name[yellow*]) in rank grey; space only when guild part is present
                    local sep = (guildLine ~= "") and " " or ""
                    guildLine = guildLine .. sep .. rColor .. "(" .. rankDisplay .. "|r" .. TRANSLATED_NAME_MARK .. rColor .. ")|r"
                end
                table.insert(lines, guildLine)
            end
            if table.getn(lines) > 0 then
                InsertTooltipLines(tooltip, lines)
                if tooltip.wtAddedNameLine then ArmTooltipLayoutWatch(tooltip) end
            end
        end)
    end)
end

-- ============================================================================
-- NAMEPLATE PLAYER NAME TRANSLATION
-- ============================================================================
-- Works with ShaguPlates (ShaguTweaks.libnameplate + ShaguPlates.nameplates).
-- Vanilla 3D-engine nameplate names cannot be intercepted; ShaguPlates is required.
-- All behavior is gated on WoWTranslateDB.translateNameplates.

local function PlayerNameClassColorEnabled()
    return WoWTranslateDB and WoWTranslateDB.playerNameClassColor
end

local function StripTranslatedNameMark(text)
    if not text then return text end
    local plain = StripColorCodes(text)
    if plain then plain = string.gsub(plain, "%*$", "") end
    return plain
end

local function StripOverheadDisplaySuffix(text)
    if not text then return text end
    local plain = StripTranslatedNameMark(text)
    local prev
    repeat
        prev = plain
        local p = string.find(plain, " %(", 1, true)
        if p then plain = string.sub(plain, 1, p - 1) end
    until plain == prev or plain == ""
    return plain
end

local function NormalizeTruncatedNameplateName(text)
    if not text then return text end
    local plain = StripOverheadDisplaySuffix(text)
    if plain and string.sub(plain, -3) == "..." then
        plain = string.sub(plain, 1, -4)
    end
    return plain
end

local function OverheadDisplayMatchesRawName(text, rawName)
    if not text or not rawName or text == "" or rawName == "" then return false end
    if text == rawName then return true end
    return StripOverheadDisplaySuffix(text) == rawName
end

-- Class from ShaguTweaks player scan (no unit id probes).
local function GetPlayerClassFromName(rawName)
    if not rawName or rawName == "" then return nil end
    if ShaguTweaks and ShaguTweaks.GetUnitData then
        local class = ShaguTweaks.GetUnitData(rawName)
        if class and class ~= "UNKNOWN" and class ~= UNKNOWN then return class end
    end
    return nil
end

-- Same color thresholds as ShaguPlates GetUnitType (reads original.healthbar).
local function GetShaguBarUnitType(r, g, b)
    if not r then return "ENEMY_NPC" end
    if r > .9 and g < .2 and b < .2 then return "ENEMY_NPC" end
    if r > .9 and g > .9 and b < .2 then return "NEUTRAL_NPC" end
    if r < .2 and g < .2 and b > .9 then return "FRIENDLY_PLAYER" end
    if r < .2 and g > .9 and b < .2 then return "FRIENDLY_NPC" end
    return "ENEMY_NPC"
end

-- Forward declarations; bodies follow after GetNameplateOverlay.
local GetNameplateFactionRgb
local GetNameplateNameTextRgb
local IsNameplatePlayerForColor

local function GetNameplateOverlay(parent)
    if not parent then return nil end
    local overlay = parent.nameplate
    if overlay and overlay.name and overlay.name.GetText and overlay.name.SetText then
        return overlay
    end
end

local function GetNameplateHealthbar(parent)
    if not parent then return nil end
    local overlay = GetNameplateOverlay(parent)
    if overlay and overlay.health and overlay.health.Hide then return overlay.health end
    if parent.wtHealthbar then return parent.wtHealthbar end
    if parent.GetChildren then
        local child = parent:GetChildren()
        if child then parent.wtHealthbar = child; return child end
    end
end

-- Hostility tint from the nameplate health bar (ShaguPlates original.healthbar).
GetNameplateFactionRgb = function(plate)
    local overlay = GetNameplateOverlay(plate)
    local bar
    if overlay and overlay.original and overlay.original.healthbar
            and overlay.original.healthbar.GetStatusBarColor then
        bar = overlay.original.healthbar
    else
        bar = GetNameplateHealthbar(plate)
    end
    if not bar or not bar.GetStatusBarColor then return 1, 0, 0 end
    local r, g, b = bar:GetStatusBarColor()
    if not r then return 1, 0, 0 end
    local ut = GetShaguBarUnitType(r, g, b)
    if ut == "NEUTRAL_NPC" then return 1, 1, 0 end
    if ut == "FRIENDLY_NPC" then return 0, 1, 0 end
    return 1, 0, 0
end

-- True when nameplate belongs to a player character (not NPC).
IsNameplatePlayerForColor = function(plate, rawName)
    local overlay = GetNameplateOverlay(plate)
    if not overlay then return false end
    if overlay.cache and overlay.cache.player == "NPC" then return false end
    if overlay.cache and overlay.cache.player == "PLAYER" then return true end
    local bar = overlay.original and overlay.original.healthbar
    if not bar or not bar.GetStatusBarColor then return false end
    local r, g, b = bar:GetStatusBarColor()
    local ut = GetShaguBarUnitType(r, g, b)
    if ut == "FRIENDLY_NPC" or ut == "NEUTRAL_NPC" then return false end
    if ut == "FRIENDLY_PLAYER" then return true end
    if rawName and rawName ~= "" then
        if ShaguPlates_playerDB and ShaguPlates_playerDB[rawName] then return true end
        if GetPlayerClassFromName(rawName) then return true end
    end
    return false
end

-- Class color for players, faction tint for NPCs; nil = let ShaguPlates color stand.
GetNameplateNameTextRgb = function(rawName, plate)
    if not plate or not PlayerNameClassColorEnabled() then return nil end
    if not IsNameplatePlayerForColor(plate, rawName) then
        return GetNameplateFactionRgb(plate)
    end
    local overlay = GetNameplateOverlay(plate)
    if overlay and overlay.original and overlay.original.name
            and overlay.original.name.GetTextColor then
        local br, bg, bb = overlay.original.name:GetTextColor()
        if br and br > .9 and bg and bg < .35 and bb and bb < .35 then
            return br, bg, bb
        end
    end
    local class = GetPlayerClassFromName(rawName)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r, c.g, c.b
    end
    return nil
end

local function FormatNameplateOverlayText(rawName, displayName)
    displayName = displayName or rawName
    local isTranslated = rawName and displayName ~= rawName
    local plain = ApplyNameCapitalization(StripColorCodes(isTranslated and displayName or rawName))
    if not isTranslated then return plain end
    return plain .. "*"
end

local function ApplyNameplateNameText(fs, formatted, parent, rawName, unit)
    if not fs or not formatted then return end
    local tr, tg, tb, ta = 1, 1, 1, 1
    local colorSet = false
    if PlayerNameClassColorEnabled() and rawName and parent then
        local cr, cg, cb = GetNameplateNameTextRgb(rawName, parent)
        if cr then tr, tg, tb = cr, cg, cb; colorSet = true end
    end
    if not colorSet and parent then
        local overlay = parent.nameplate
        if overlay and overlay.original and overlay.original.name
                and overlay.original.name.GetTextColor then
            tr, tg, tb, ta = overlay.original.name:GetTextColor()
        elseif fs.GetTextColor then
            tr, tg, tb, ta = fs:GetTextColor()
        end
    elseif not colorSet and fs.GetTextColor then
        tr, tg, tb, ta = fs:GetTextColor()
    end
    fs:SetText(formatted)
    if fs.SetTextColor then fs:SetTextColor(tr, tg, tb, ta or 1) end
    if fs.GetStringWidth and fs.SetWidth then
        local w = fs:GetStringWidth()
        if w and w > 0 then fs:SetWidth(w + 8) end
    end
end

local wtNameplateShaguHooked = false
local wtShaguPlatesHooked    = false
local NAMEPLATE_NAME_UPDATE_INTERVAL = 0.2

local function NameplateNameUpdateDue(plate)
    if not plate then return true end
    local now = GetTime()
    if plate.wtNextNameUpdate and now < plate.wtNextNameUpdate then return false end
    plate.wtNextNameUpdate = now + NAMEPLATE_NAME_UPDATE_INTERVAL
    return true
end

local function GetNameplateDisplayNameFont(parent)
    local overlay = GetNameplateOverlay(parent)
    if overlay then return overlay.name end
    return nil
end

local function ResolveNameplateRawName(plate)
    if not plate then return nil end
    local overlay = GetNameplateOverlay(plate)
    if not overlay then return plate.wtRawName end
    if overlay.cache and overlay.cache.name and overlay.cache.name ~= "" then
        return NormalizeTruncatedNameplateName(overlay.cache.name)
    end
    if overlay.original and overlay.original.name and overlay.original.name.GetText then
        local t = overlay.original.name:GetText()
        if t and t ~= "" then
            return NormalizeTruncatedNameplateName(StripOverheadDisplaySuffix(t))
        end
    end
    return nil
end

local function UpdateNameplateFromPlate(plate)
    if not plate then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if not WoWTranslateDB.translateNameplates then return end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end

    local overlay = GetNameplateOverlay(plate)
    if not overlay then return end

    local rawName = ResolveNameplateRawName(plate)
    if not rawName or rawName == "" then return end
    plate.wtRawName = rawName

    if ShouldTranslatePlayerName(rawName) then
        local fs = overlay.name
        if fs and fs.GetText then
            if plate.wtLastDisplay then
                local cur = fs:GetText()
                if cur then
                    local plain = NormalizeTruncatedNameplateName(cur)
                    if plain == rawName or OverheadDisplayMatchesRawName(cur, rawName) then
                        plate.wtLastDisplay = nil
                    end
                end
            end
            local current = fs:GetText() or ""
            if not (plate.wtLastDisplay and current == plate.wtLastDisplay) then
                local cached, found = WoWTranslate_CacheGet(NameCacheKey(rawName))
                local function applyNameDisplay(displayName)
                    if plate.wtRawName ~= rawName then return end
                    local formatted = FormatNameplateOverlayText(rawName, displayName)
                    if plate.wtLastDisplay ~= formatted then
                        ApplyNameplateNameText(fs, formatted, plate, rawName, nil)
                        plate.wtLastDisplay = formatted
                        if overlay.name and overlay.name.Show then overlay.name:Show() end
                    end
                end
                if found then
                    applyNameDisplay(cached)
                elseif not plate.wtResolvePending then
                    plate.wtResolvePending = true
                    ResolvePlayerDisplayName(rawName, function(displayName)
                        plate.wtResolvePending = nil
                        if plate.wtRawName ~= rawName then return end
                        if displayName then applyNameDisplay(displayName) end
                    end)
                end
            end
        end
    end
end

local function ResetNameplatePlateState(plate)
    if not plate then return end
    plate.wtRawName             = nil
    plate.wtLastDisplay         = nil
    plate.wtResolvePending      = nil
    plate.wtNextNameUpdate      = nil
    plate.wtLastGuildDisplay    = nil
    plate.wtGuildResolvePending = nil
    plate.wtPendingRawGuild     = nil
    plate.wtOOCClutterHidden    = nil
    plate.wtClutterFrames       = nil
    plate.wtNameDetachedForOOC  = nil
    if plate.wtGuildLine and plate.wtGuildLine.Hide then plate.wtGuildLine:Hide() end
end

-- ============================================================================
-- 非战斗状态隐藏血条 + 显示公会名（仅支持 ShaguPlates）
-- ============================================================================

local function IsNameplateUnitInCombat(plate)
    if not UnitAffectingCombat then return true end
    local ok, c = pcall(UnitAffectingCombat, "player")
    return ok and c
end

-- ShaguPlates 默认把名字放在血条下面；脱离战斗时分离结构，让名字保持显示
local function EnsureOverlayNameDetached(parent)
    local overlay = GetNameplateOverlay(parent)
    if not overlay or not overlay.name then return end
    if not WoWTranslateDB or not WoWTranslateDB.nameplateHideHealthOOC then
        parent.wtNameDetachedForOOC = nil; return
    end
    if IsNameplateUnitInCombat(parent) then
        parent.wtNameDetachedForOOC = nil; return
    end
    if overlay.name:GetParent() ~= overlay then
        overlay.name:SetParent(overlay)
    end
    overlay.name:ClearAllPoints()
    overlay.name:SetPoint("TOP", overlay, "TOP", 0, 0)
    overlay.name:Show()
    parent.wtNameDetachedForOOC = true
end

-- 血条、背景、等级文字 —— 非战斗时统一隐藏
local function CollectNameplateClutterFrames(parent)
    local frames = {}
    local function add(f)
        if f and f.Hide and f.Show then table.insert(frames, f) end
    end
    local overlay = GetNameplateOverlay(parent)
    if overlay then
        local bar = overlay.health
        add(bar)
        if bar and bar.backdrop then add(bar.backdrop) end
        if overlay.level and overlay.level.Hide then add(overlay.level) end
    end
    return frames
end

local function SetNameplateClutterVisible(plate, visible)
    local frames = plate.wtClutterFrames
    for i = 1, table.getn(frames) do
        if visible then frames[i]:Show() else frames[i]:Hide() end
    end
    plate.wtOOCClutterHidden = not visible or nil
end

-- ============================================================================
-- 非战斗状态显示公会名（仅支持 ShaguPlates）
-- ============================================================================

local wtNameplateGuildByPlayer = {}

local function LookupRawGuildForNameplate(rawName)
    if not rawName or rawName == "" then return nil end
    if wtNameplateGuildByPlayer[rawName] then return wtNameplateGuildByPlayer[rawName] end
    if ShaguPlates_playerDB and ShaguPlates_playerDB[rawName] then
        local g = ShaguPlates_playerDB[rawName].guild
        if g and g ~= "" then wtNameplateGuildByPlayer[rawName] = g; return g end
    end
    local unit = FindPlayerUnitByName(rawName)
    if unit and GetGuildInfo then
        local ok, guild = pcall(GetGuildInfo, unit)
        if ok and guild and guild ~= "" then
            wtNameplateGuildByPlayer[rawName] = guild; return guild
        end
    end
    return nil
end

local function FormatNameplateGuildLine(rawGuild, displayGuild)
    displayGuild = displayGuild or rawGuild
    if not displayGuild or displayGuild == "" then return nil end
    local plain = StripColorCodes(displayGuild) or displayGuild
    local line = "<" .. plain .. ">"
    if rawGuild and displayGuild ~= rawGuild then line = line .. "*" end
    return line
end

local function EnsureNameplateGuildFont(plate, nameFs)
    if plate.wtGuildLine and plate.wtGuildLine.SetText then return plate.wtGuildLine end
    local overlay = GetNameplateOverlay(plate)
    local parent = overlay or plate
    local anchor = (overlay and overlay.name and overlay.name.GetText and overlay.name) or nameFs
    if not anchor then return nil end
    local fs = parent:CreateFontString("WoWTranslateNameplateGuild", "OVERLAY")
    if anchor.GetFont and fs.SetFont then
        local font, size, flags = anchor:GetFont()
        local small = (size and size > 8) and (size - 2) or 10
        if font then fs:SetFont(font, small, flags) end
    end
    fs:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    plate.wtGuildLine = fs
    return fs
end

local function HideNameplateGuildLine(plate)
    if not plate then return end
    if plate.wtGuildLine and plate.wtGuildLine.Hide then plate.wtGuildLine:Hide() end
    plate.wtLastGuildDisplay    = nil
    plate.wtGuildResolvePending = nil
    plate.wtPendingRawGuild     = nil
end

local function UpdateNameplateGuildOOC(plate)
    if not plate then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled or not WoWTranslateDB.nameplateGuildOOC then
        HideNameplateGuildLine(plate); return
    end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then
        HideNameplateGuildLine(plate); return
    end
    if IsNameplateUnitInCombat(plate) then
        HideNameplateGuildLine(plate); return
    end

    local rawName = plate.wtRawName
    if not rawName or rawName == "" then HideNameplateGuildLine(plate); return end
    if not IsNameplatePlayerForColor(plate, rawName) then
        HideNameplateGuildLine(plate); return
    end

    local nameFs = GetNameplateDisplayNameFont(plate)
    if not nameFs then return end

    EnsureOverlayNameDetached(plate)

    local guildFs = EnsureNameplateGuildFont(plate, nameFs)
    if not guildFs then return end

    local overlay = GetNameplateOverlay(plate)
    local guildAnchor = (overlay and overlay.name) or nameFs
    guildFs:ClearAllPoints()
    guildFs:SetPoint("TOP", guildAnchor, "BOTTOM", 0, -2)

    local rawGuild = LookupRawGuildForNameplate(rawName)
    if not rawGuild or rawGuild == "" then HideNameplateGuildLine(plate); return end
    plate.wtPendingRawGuild = rawGuild

    local function showLine(displayGuild)
        if (plate.wtRawName or "") ~= rawName then return end
        local line = FormatNameplateGuildLine(rawGuild, displayGuild)
        if not line then HideNameplateGuildLine(plate); return end
        if plate.wtLastGuildDisplay == line then
            if guildFs.IsShown then
                local s = guildFs:IsShown()
                if s == 1 or s == true then return end
            end
        end
        plate.wtLastGuildDisplay = line
        guildFs:SetText(line)
        guildFs:Show()
    end

    if WoWTranslateDB.translateGuildNames and WoWTranslate_ResolveGuildDisplayName then
        local cacheKey = NameCacheKey("guild:" .. rawGuild)
        local cached, found = WoWTranslate_CacheGet(cacheKey)
        if found then showLine(cached); return end
        if plate.wtGuildResolvePending == rawName then
            if plate.wtLastGuildDisplay then
                guildFs:SetText(plate.wtLastGuildDisplay); guildFs:Show()
            end
            return
        end
        plate.wtGuildResolvePending = rawName
        WoWTranslate_ResolveGuildDisplayName(rawGuild, function(displayGuild)
            plate.wtGuildResolvePending = nil
            showLine(displayGuild)
        end)
        return
    end

    showLine(rawGuild)
end

local function UpdateNameplateHealthbarVisibility(plate)
    if not plate then return end
    EnsureOverlayNameDetached(plate)
    if not plate.wtClutterFrames or table.getn(plate.wtClutterFrames) == 0 then
        plate.wtClutterFrames = CollectNameplateClutterFrames(plate)
    end
    if table.getn(plate.wtClutterFrames) > 0 then
        if not WoWTranslateDB or not WoWTranslateDB.nameplateHideHealthOOC then
            if plate.wtOOCClutterHidden then SetNameplateClutterVisible(plate, true) end
        elseif IsNameplateUnitInCombat(plate) then
            if plate.wtOOCClutterHidden then SetNameplateClutterVisible(plate, true) end
        else
            SetNameplateClutterVisible(plate, false)
        end
    end
    UpdateNameplateGuildOOC(plate)
end

-- ============================================================================

function WoWTranslate_OnNameplateUpdate(plate)
    plate = plate or this
    if not plate then return end
    if not GetNameplateOverlay(plate) then return end
    if not NameplateNameUpdateDue(plate) then return end
    UpdateNameplateFromPlate(plate)
    UpdateNameplateHealthbarVisibility(plate)
end

function WoWTranslate_OnNameplateShow(plate)
    plate = plate or this
    if not plate then return end
    ResetNameplatePlateState(plate)
end

local function HookShaguNameplates()
    local lib = ShaguTweaks and ShaguTweaks.libnameplate
    if not lib then return false end
    if not lib.wtWoWTranslateHooked then
        table.insert(lib.OnUpdate, function(plate)
            WoWTranslate_OnNameplateUpdate(plate)
        end)
        table.insert(lib.OnShow, function(plate)
            WoWTranslate_OnNameplateShow(plate)
        end)
        lib.wtWoWTranslateHooked = true
    end
    wtNameplateShaguHooked = true
    return true
end

local function HookShaguPlatesNameplates()
    if not ShaguPlates or not ShaguPlates.nameplates then return false end
    local np = ShaguPlates.nameplates
    if np.wtWoWTranslateWrapped then
        wtShaguPlatesHooked = true
        return true
    end
    local base = np.wtWoWTranslateBase or np.OnDataChanged
    if not base then return false end
    if not np.wtWoWTranslateBase then np.wtWoWTranslateBase = base end
    np.OnDataChanged = function(self, overlay)
        np.wtWoWTranslateBase(self, overlay)
        local parent = overlay and overlay.parent
        if not parent then return end
        if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
        if not WoWTranslateDB.translateNameplates then return end
        if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
        parent.wtNextNameUpdate = nil
        UpdateNameplateFromPlate(parent)
        UpdateNameplateHealthbarVisibility(parent)
    end
    np.wtWoWTranslateWrapped = true
    wtShaguPlatesHooked = true
    return true
end

local function HookNameplates()
    if not WoWTranslateDB or not WoWTranslateDB.translateNameplates then return end
    HookShaguNameplates()
    HookShaguPlatesNameplates()
end
-- 提前引用：允许在游戏中开启翻译功能时自动挂钩 ShaguPlates
wtNameplateScanStart = HookNameplates

-- ============================================================================
-- 组队查找器（LFT）自动翻译
-- ============================================================================
-- 翻译每个可见队伍条目的标题和描述
-- 挂钩 LFT_UpdateGroupsList；需要 LFT 插件已加载
-- 由 WoWTranslateDB.translateGroupFinder 控制开关

local lftHooked = false

-- 异步翻译完成后，找到仍在显示的条目并更新文字
local function LFT_ApplyTranslation(entryId, isTitle, translated)
    for i = 1, 8 do
        local btn = _G["LFTFrameGroupEntry"..i]
        if btn and btn:IsShown() and btn.data and btn.data.id == entryId then
            local suffix = isTitle and "Text" or "SubText"
            local widget = _G["LFTFrameGroupEntry"..i..suffix]
            if widget then widget:SetText(translated) end
        end
    end
end

local function LFT_TranslateField(entryId, rawText, isTitle)
    if not rawText or rawText == "" then return end
    local detectedLang = DetectSourceLanguage(rawText)
    if not detectedLang then return end

    -- 读取缓存：立即显示，不请求API
    local cached, found = WoWTranslate_CacheGet(rawText)
    if found then
        LFT_ApplyTranslation(entryId, isTitle, cached)
        return
    end

    -- 术语库完全匹配
    if WoWTranslate_CheckGlossaryExact then
        local glossaryResult = WoWTranslate_CheckGlossaryExact(rawText)
        if glossaryResult then
            WoWTranslate_CacheSave(rawText, glossaryResult)
            LFT_ApplyTranslation(entryId, isTitle, glossaryResult)
            return
        end
    end

    -- 术语库部分替换后再翻译
    local textToTranslate = rawText
    if WoWTranslate_CheckGlossaryPartial then
        local partial = WoWTranslate_CheckGlossaryPartial(rawText)
        if partial then textToTranslate = partial end
    end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then return end
    WoWTranslate_API.Translate(textToTranslate, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(rawText, translation)
            LFT_ApplyTranslation(entryId, isTitle, translation)
        end
    end, detectedLang)
end

local function LFT_ScanVisibleEntries()
    if not WoWTranslateDB or not WoWTranslateDB.translateGroupFinder then return end
    if not WoWTranslateDB.enabled then return end
    for i = 1, 8 do
        local btn = _G["LFTFrameGroupEntry"..i]
        if btn and btn:IsShown() and btn.data then
            local entry = btn.data
            LFT_TranslateField(entry.id, entry.title, true)
            LFT_TranslateField(entry.id, entry.description, false)
        end
    end
end

local function HookLFT()
    if lftHooked then return end
    if not LFT_UpdateGroupsList then return end
    local originalUpdate = LFT_UpdateGroupsList
    LFT_UpdateGroupsList = function()
        originalUpdate()
        LFT_ScanVisibleEntries()
    end
    lftHooked = true
end

function WoWTranslate_SetTranslateGroupFinder(enabled)
    if WoWTranslateDB then
        WoWTranslateDB.translateGroupFinder = enabled
    end
    if enabled then
        HookLFT()
        -- 如果LFT窗口已打开，立即刷新
        if LFTFrame and LFTFrame:IsShown() then
            LFT_ScanVisibleEntries()
        end
    end
end

-- ============================================================================
local function HookGameTooltip()
    if not GameTooltip then return end
    if GameTooltip.WoWTranslateOrigSetUnit then
        GameTooltip.SetUnit = GameTooltip.WoWTranslateOrigSetUnit
    end
    if GameTooltip.WoWTranslateOrigSetHyperlink then
        GameTooltip.SetHyperlink = GameTooltip.WoWTranslateOrigSetHyperlink
    end
    if not GameTooltip.WoWTranslateOrigSetUnit then
        GameTooltip.WoWTranslateOrigSetUnit = GameTooltip.SetUnit
    end
    if GameTooltip.SetHyperlink and not GameTooltip.WoWTranslateOrigSetHyperlink then
        GameTooltip.WoWTranslateOrigSetHyperlink = GameTooltip.SetHyperlink
    end
    GameTooltip.WoWTranslateTooltipHooked = true
    local origSetUnit = GameTooltip.WoWTranslateOrigSetUnit
    function GameTooltip:SetUnit(unit)
        ClearTooltipNameHeader(GameTooltip)
        GameTooltip.wtUnit = unit
        GameTooltip.wtPlayerName = nil
        GameTooltip.wtNameResolvePending = nil
        if unit and UnitExists(unit) and UnitIsPlayer(unit) then
            GameTooltip.wtPlayerName = UnitName(unit)
        end
        if origSetUnit then return origSetUnit(self, unit) end
    end
    if GameTooltip.WoWTranslateOrigSetHyperlink then
        local origSetHyperlink = GameTooltip.WoWTranslateOrigSetHyperlink
        function GameTooltip:SetHyperlink(link)
            ClearTooltipNameHeader(GameTooltip)
            GameTooltip.wtUnit = nil
            GameTooltip.wtPlayerName = ParsePlayerHyperlink(link)
            GameTooltip.wtNameResolvePending = nil
            if origSetHyperlink then return origSetHyperlink(self, link) end
        end
    end
    if not wtTooltipFrame then wtTooltipFrame = getglobal("WoWTranslateTooltipFrame") end
    if not wtTooltipFrame then
        wtTooltipFrame = CreateFrame("Frame", "WoWTranslateTooltipFrame", GameTooltip)
        local function DeferUpdateGameTooltip()
            if not TooltipIsShown(GameTooltip) then return end
            if GameTooltip.wtAddedNameLine or GameTooltip.wtNameResolvePending then return end
            UpdateTooltipPlayerNames(GameTooltip)
        end
        local function ArmTooltipDefer()
            wtTooltipFrame.elapsed = 0
            wtTooltipFrame:SetScript("OnUpdate", function()
                if not TooltipIsShown(GameTooltip) then
                    wtTooltipFrame.elapsed = 0
                    wtTooltipFrame:SetScript("OnUpdate", nil)
                    return
                end
                if GameTooltip.wtAddedNameLine or GameTooltip.wtNameResolvePending then
                    wtTooltipFrame:SetScript("OnUpdate", nil)
                    return
                end
                wtTooltipFrame.elapsed = wtTooltipFrame.elapsed + arg1
                if wtTooltipFrame.elapsed < 0.4 then return end
                wtTooltipFrame:SetScript("OnUpdate", nil)
                DeferUpdateGameTooltip()
            end)
        end
        wtTooltipFrame:SetScript("OnShow", function() ArmTooltipDefer() end)
        if not GameTooltip.WoWTranslateOrigOnHide then
            GameTooltip.WoWTranslateOrigOnHide = GameTooltip:GetScript("OnHide")
        end
        local origOnHide = GameTooltip.WoWTranslateOrigOnHide
        GameTooltip:SetScript("OnHide", function()
            ClearTooltipNameHeader(GameTooltip)
            GameTooltip.wtUnit = nil
            GameTooltip.wtPlayerName = nil
            GameTooltip.wtNameResolvePending = nil
            if origOnHide then origOnHide() end
        end)
    end
end

local function HookItemRefTooltip()
    if not ItemRefTooltip then return end
    if ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        ItemRefTooltip.SetHyperlink = ItemRefTooltip.WoWTranslateOrigSetHyperlink
    end
    if ItemRefTooltip.SetHyperlink and not ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        ItemRefTooltip.WoWTranslateOrigSetHyperlink = ItemRefTooltip.SetHyperlink
    end
    ItemRefTooltip.WoWTranslateTooltipHooked = true
    if ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        local origSetHyperlink = ItemRefTooltip.WoWTranslateOrigSetHyperlink
        function ItemRefTooltip:SetHyperlink(link)
            ClearTooltipNameHeader(ItemRefTooltip)
            ItemRefTooltip.wtUnit = nil
            ItemRefTooltip.wtPlayerName = ParsePlayerHyperlink(link)
            ItemRefTooltip.wtNameResolvePending = nil
            if origSetHyperlink then return origSetHyperlink(self, link) end
        end
    end
    local refFrame = getglobal("WoWTranslateItemRefTooltipFrame")
    if not refFrame then
        refFrame = CreateFrame("Frame", "WoWTranslateItemRefTooltipFrame", ItemRefTooltip)
        refFrame:SetScript("OnShow", function()
            refFrame.elapsed = 0
            refFrame:SetScript("OnUpdate", function()
                if not TooltipIsShown(ItemRefTooltip) then
                    refFrame:SetScript("OnUpdate", nil); return
                end
                if ItemRefTooltip.wtAddedNameLine or ItemRefTooltip.wtNameResolvePending then
                    refFrame:SetScript("OnUpdate", nil); return
                end
                refFrame.elapsed = refFrame.elapsed + arg1
                if refFrame.elapsed < 0.25 then return end
                refFrame:SetScript("OnUpdate", nil)
                UpdateTooltipPlayerNames(ItemRefTooltip)
            end)
        end)
        if not ItemRefTooltip.WoWTranslateOrigOnHide then
            ItemRefTooltip.WoWTranslateOrigOnHide = ItemRefTooltip:GetScript("OnHide")
        end
        local refOrigOnHide = ItemRefTooltip.WoWTranslateOrigOnHide
        ItemRefTooltip:SetScript("OnHide", function()
            ClearTooltipNameHeader(ItemRefTooltip)
            ItemRefTooltip.wtPlayerName = nil
            ItemRefTooltip.wtNameResolvePending = nil
            if refOrigOnHide then refOrigOnHide() end
        end)
    end
end

local function HookTooltips()
    HookGameTooltip()
    HookItemRefTooltip()
    HookNameplates()
end

-- ============================================================================
-- 发送消息翻译开关按钮
-- ============================================================================
local outgoingButton = nil

local function UpdateOutgoingButton()
    if not outgoingButton then return end
    if WoWTranslateDB and WoWTranslateDB.outgoingEnabled then
        outgoingButton:SetText("|cFF00FF00发送:开启|r")
    else
        outgoingButton:SetText("|cFFFF4444发送:关闭|r")
    end
end

local function CreateOutgoingButton()
    if outgoingButton then return end
    local f = CreateFrame("Button", "WoWTranslateOutgoingButton", UIParent)
    outgoingButton = f
    f:SetWidth(48)
    f:SetHeight(15)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "",
        tile = true, tileSize = 8, edgeSize = 0,
        insets = { left=0, right=0, top=0, bottom=0 },
    })
    f:SetBackdropColor(0, 0, 0, 0.7)

    local pos = WoWTranslateDB and WoWTranslateDB.outgoingButtonPos or { x=100, y=100 }
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetAllPoints(f)
    f.label = label

    f:SetScript("OnMouseDown", function()
        -- 点击仅做视觉反馈，松开时切换状态
    end)
    f:SetScript("OnMouseUp", function()
        if arg1 == "LeftButton" then
            local nowEnabled = not (WoWTranslateDB and WoWTranslateDB.outgoingEnabled)
            WoWTranslate_SetOutgoingEnabled(nowEnabled)
        end
    end)
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local x = f:GetLeft()
        local y = f:GetBottom()
        if WoWTranslateDB then
            WoWTranslateDB.outgoingButtonPos = { x = x, y = y }
        end
    end)

    -- 暴露 SetText 方法，方便统一更新按钮文字
    function f:SetText(text) self.label:SetText(text) end

    if WoWTranslateDB and WoWTranslateDB.showOutgoingButton == false then
        f:Hide()
    else
        f:Show()
    end
    UpdateOutgoingButton()
end

local function ApplyOutgoingButtonVisibility()
    if not outgoingButton then return end
    if WoWTranslateDB and WoWTranslateDB.showOutgoingButton == false then
        outgoingButton:Hide()
    else
        outgoingButton:Show()
    end
end

-- ============================================================================
-- force=true 会清除 WoWTranslateHooked 标记，让所有框架重新挂钩（用于 /wt reset）。
-- origScript 会保存在框架上，确保重新挂钩时始终包裹原始的魔兽处理函数，
-- 不会重复包裹 WoWTranslate 自身的包装函数。
local function HookChatFrames(force)
    if not originalAddMessage and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        originalAddMessage = DEFAULT_CHAT_FRAME.AddMessage
    end

    for i = 1, NUM_CHAT_WINDOWS do
        local frameName = "ChatFrame" .. i
        local frame = getglobal(frameName)

        if frame then
            if force then frame.WoWTranslateHooked = false end

            if not frame.WoWTranslateHooked then
                -- 重新挂钩时使用保存的原始脚本，避免嵌套包裹
                local origScript = frame.WoWTranslate_OrigScript or frame:GetScript("OnEvent")
                if not origScript then
                    DebugLog("框架无 OnEvent 脚本", frameName)
                else
                    frame.WoWTranslate_OrigScript = origScript  -- 持久保存，用于安全重挂钩
                    frame.WoWTranslateHooked = true

                    frame:SetScript("OnEvent", function()
                        hookCallCount = hookCallCount + 1

                        -- 在原始脚本覆盖全局变量前，先保存事件参数
                        local capturedEvent = event
                        local capturedArg1  = arg1
                        local capturedArg2  = arg2
                        local capturedArg4  = arg4  -- CHAT_MSG_CHANNEL 的频道名称
                        local capturedThis  = this

                        -- 使用 pcall 包裹：魔兽 1.12 中，SetScript 处理函数内的未捕获错误会静默禁用它
                        local _ok, _err = pcall(function()
                            -- 由魔兽自带过滤器判断：如果原始脚本没有在该框架显示消息（被过滤），则不显示翻译
                            local msgsBefore = capturedThis:GetNumMessages()
                            local messageShownInFrame = false
                            local origFrameAddMsg = capturedThis.AddMessage
                            local pendingArgs = nil

                            capturedThis.AddMessage = function(f, a, b, c, d, e, g)
                                messageShownInFrame = true
                                capturedThis.AddMessage = origFrameAddMsg
                                local manualId = StoreManualTranslateRecord(capturedThis, capturedEvent, capturedArg1, capturedArg2, capturedArg4)
                                a = AppendManualTranslateLink(a, manualId)
                                if WoWTranslateDB and WoWTranslateDB.replaceMode then
                                    -- 替换模式：隐藏原始消息，保存参数
                                    pendingArgs = {f=f, a=a, b=b, c=c, d=d, e=e, g=g}
                                else
                                    origFrameAddMsg(f, a, b, c, d, e, g)
                                end
                            end

                            -- 翻译失败时，恢复显示原始消息
                            local function FlushOriginal()
                                if pendingArgs then
                                    origFrameAddMsg(pendingArgs.f, pendingArgs.a, pendingArgs.b,
                                                    pendingArgs.c, pendingArgs.d, pendingArgs.e,
                                                    pendingArgs.g)
                                    pendingArgs = nil
                                end
                            end

                            local origOk, origErr = pcall(origScript)
                            
                            -- 无论如何都恢复原始 AddMessage
                            capturedThis.AddMessage = origFrameAddMsg

                            if not origOk then
                                DebugLog("原始脚本错误:", tostring(origErr))
                                FlushOriginal(); return
                            end

                            if not messageShownInFrame then
                                -- 阴影检测未触发，使用消息数量作为降级方案
                                local msgsAfter = capturedThis:GetNumMessages()
                                if msgsAfter < msgsBefore
                                    or (msgsAfter == msgsBefore and msgsBefore < 128)then
                                    FlushOriginal(); return
                                end
                            end

                            if not WoWTranslateDB or not WoWTranslateDB.enabled then FlushOriginal(); return end
                            if WoWTranslateDB.disableWhileAfk and playerIsAFK then FlushOriginal(); return end

                            local channel  = EVENT_TO_CHANNEL[capturedEvent]
                            local isSystem = SYSTEM_EVENTS[capturedEvent]
                            if not channel and not isSystem then FlushOriginal(); return end
                            if isSystem and not WoWTranslateDB.translateSystemMessages then FlushOriginal(); return end

                            if channel then
                                local inChannels = WoWTranslateDB.incomingChannels
                                local effectiveChannel = channel
                                if channel == "CHANNEL" and capturedArg4 then
                                    local chanName = string.gsub(capturedArg4, "^%d+%.%s*", "")
                                    if string.find(string.lower(chanName), "^english") then
                                        effectiveChannel = "ENGLISH"
                                    end
                                end
                                if inChannels and not inChannels[effectiveChannel] then FlushOriginal(); return end
                            end

                            if not capturedArg1 or capturedArg1 == "" then FlushOriginal(); return end
                            if string.sub(capturedArg1, 1, 1) == "#" then FlushOriginal(); return end
                            -- 移除其他玩家发送的 WoWTranslate 前缀
                            do
                                local p = string.find(capturedArg1, "WoWTranslate", 1, true)
                                if p and p <= 50 then
                                    local closeBracket = string.find(capturedArg1, "]", p, true)
                                    if closeBracket then
                                        local stripped = string.gsub(string.sub(capturedArg1, closeBracket + 1), "^%s+", "")
                                        if stripped ~= "" then capturedArg1 = stripped end
                                    end
                                end
                            end

                            local detectedLang = DetectSourceLanguage(capturedArg1)
                            DebugLog("事件:", capturedEvent, "语言=", tostring(detectedLang), "消息=", string.sub(capturedArg1, 1, 30))
                            if not detectedLang then FlushOriginal(); return end
                            -- 跳过无意义翻译（如中文→中文）
                            local incomingTargetLang = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
                            if detectedLang == incomingTargetLang then FlushOriginal(); return end

                            local resolvedSenderName = capturedArg2
                            local resolvedGuildName  = nil

                            local channelTag   = GetChannelTag(capturedEvent, capturedArg4)
                            local msgColor     = (WoWTranslateDB and WoWTranslateDB.translationColor) or ""
                            local chanColorHex = GetChatTypeColorHex(capturedEvent, capturedArg4)
                            local chanNamePart = string.sub(channelTag, 1, 3) == "WT-" and string.sub(channelTag, 4) or nil

                            local wimWhisperUser = nil

                            local function BuildWTMsg(body)
                                local prefix
                                if chanColorHex and chanNamePart then
                                    prefix = "|cFF00FFFF[WT-|r|cFF" .. chanColorHex .. chanNamePart .. "]|r"
                                else
                                    prefix = "|cFF00FFFF[" .. channelTag .. "]|r"
                                end
                                local bodyHex = msgColor
                                if WoWTranslateDB and WoWTranslateDB.translationColorFollow then
                                    bodyHex = chanColorHex or ""
                                end
                                local displayBody = bodyHex ~= "" and ("|cFF" .. bodyHex .. body .. "|r") or body
                                local sp = BuildSenderPrefix(capturedArg2, resolvedSenderName, channel, resolvedGuildName)
                                return prefix .. " " .. sp .. displayBody
                            end

                            local function ResolveNamesAndPost(body, postFn)
                                ResolvePlayerDisplayName(capturedArg2, function(dName)
                                    resolvedSenderName = dName
                                    resolvedGuildName  = nil
                                    postFn(BuildWTMsg(body))
                                end)
                            end

                            local function PostWTMsg(wtMsg)
                                if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                    WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                else
                                    capturedThis:AddMessage(wtMsg)
                                end
                            end

                            -- 分割文本与超链接，只翻译纯文本部分
                            local segments = SplitIntoSegments(capturedArg1)
                            if not HasTranslatableContent(segments) then FlushOriginal(); return end

                            local plainText = BuildTranslatableText(segments)

                            -- 为该消息注册接收翻译的聊天框架
                            if not messageShownInFrame then
                                -- WIM 兼容：WIM 会隐藏密语，直接发送到 WIM 窗口
                                if (capturedEvent == "CHAT_MSG_WHISPER" or capturedEvent == "CHAT_MSG_WHISPER_INFORM") and
                                   type(WIM_Data) == "table" and WIM_Data.enableWIM and
                                   WIM_Data.supressWisps ~= false and
                                   type(WIM_PostMessage) == "function" and
                                   capturedArg2 and capturedArg2 ~= "" then
                                    wimWhisperUser = capturedArg2
                                else
                                    FlushOriginal(); return
                                end
                            end
                            if not wimWhisperUser then
                                if not frameTranslationTargets[capturedArg1] then
                                    frameTranslationTargets[capturedArg1] = {}
                                end
                                frameTranslationTargets[capturedArg1][capturedThis] = true
                            end

                            -- 读取缓存
                            local cached, found = WoWTranslate_CacheGet(capturedArg1)
                            if found then
                                DebugLog("缓存命中")
                                local reconstructed = ReconstructMessage(segments, cached)
                                frameTranslationTargets[capturedArg1] = nil
                                ResolveNamesAndPost(reconstructed, PostWTMsg)
                                return
                            end

                            local textToTranslate = plainText
                            if detectedLang == "en" then
                                -- 英文来源：应用外向词汇表（英→中）
                                if WoWTranslate_CheckOutGlossaryExact then
                                    local r = WoWTranslate_CheckOutGlossaryExact(plainText)
                                    if r then
                                        DebugLog("外向词汇表精确匹配（英文输入）:", r)
                                        WoWTranslate_CacheSave(capturedArg1, r)
                                        frameTranslationTargets[capturedArg1] = nil
                                        ResolveNamesAndPost(ReconstructMessage(segments, r), PostWTMsg)
                                        return
                                    end
                                end
                                if WoWTranslate_CheckOutGlossaryPartial then
                                    local r = WoWTranslate_CheckOutGlossaryPartial(plainText)
                                    if r then
                                        DebugLog("外向词汇表部分匹配（英文输入）:", r)
                                        textToTranslate = r
                                    end
                                end
                            else
                                -- 预处理：货币、网络用语
                                plainText = PreprocessIncoming(plainText)
                                textToTranslate = plainText
                                -- 应用内向词汇表（中→英）
                                local glossaryResult = WoWTranslate_CheckGlossaryExact(plainText)
                                if glossaryResult then
                                    DebugLog("词汇表精确匹配:", glossaryResult)
                                    WoWTranslate_CacheSave(capturedArg1, glossaryResult)
                                    frameTranslationTargets[capturedArg1] = nil
                                    ResolveNamesAndPost(ReconstructMessage(segments, glossaryResult), PostWTMsg)
                                    return
                                end
                                local partialResult = WoWTranslate_CheckGlossaryPartial(plainText)
                                if partialResult then
                                    if not DetectSourceLanguage(partialResult) then
                                        DebugLog("词汇表完全处理:", partialResult)
                                        WoWTranslate_CacheSave(capturedArg1, partialResult)
                                        frameTranslationTargets[capturedArg1] = nil
                                        ResolveNamesAndPost(ReconstructMessage(segments, partialResult), PostWTMsg)
                                        return
                                    end
                                    textToTranslate = partialResult
                                    DebugLog("词汇表预处理完成，请求API")
                                end
                            end

                            if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
                                if not dllWarnShown then
                                    dllWarnShown = true
                                    capturedThis:AddMessage("|cFFFFFF00[WoWTranslate] 翻译核心未加载 - 输入 /wt status 查看|r")
                                end
                                FlushOriginal(); return
                            end

                            local replacePendingKey = nil
                            local replacePendingData = nil
                            if pendingArgs then
                                replacePendingData = {
                                    originalAddMessage = origFrameAddMsg,
                                    frame              = pendingArgs.f,
                                    originalText       = pendingArgs.a,
                                    r = pendingArgs.b, g = pendingArgs.c, b = pendingArgs.d,
                                    id = pendingArgs.e, holdTime = pendingArgs.g,
                                }
                                pendingArgs = nil
                            end

                            local apiQueued = WoWTranslate_API.Translate(textToTranslate, function(translation, err)
                                if translation and translation ~= "" then
                                    DebugLog("翻译结果:", string.sub(translation, 1, 50))
                                    translationErrWarnShown = false
                                    WoWTranslate_CacheSave(capturedArg1, translation)
                                    local reconstructed = ReconstructMessage(segments, translation)
                                    if replacePendingKey then
                                        pendingMessages[replacePendingKey] = nil
                                    end
                                    local targets = frameTranslationTargets[capturedArg1]
                                    frameTranslationTargets[capturedArg1] = nil
                                    ResolveNamesAndPost(reconstructed, function(wtMsg)
                                        if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                            WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                        elseif targets then
                                            for targetFrame in pairs(targets) do
                                                targetFrame:AddMessage(wtMsg)
                                            end
                                        else
                                            DEFAULT_CHAT_FRAME:AddMessage(wtMsg)
                                        end
                                    end)
                                else
                                    DebugLog("翻译错误:", tostring(err))
                                    frameTranslationTargets[capturedArg1] = nil
                                    if replacePendingKey then
                                        local rp = pendingMessages[replacePendingKey]
                                        if rp then
                                            pendingMessages[replacePendingKey] = nil
                                            rp.originalAddMessage(rp.frame, rp.originalText,
                                                rp.r, rp.g, rp.b, rp.id, rp.holdTime)
                                        end
                                    end
                                    if not translationErrWarnShown then
                                        translationErrWarnShown = true
                                        capturedThis:AddMessage("|cFFFFFF00[WoWTranslate] 翻译失败 (" .. tostring(err) .. ") - 请尝试 /wt reset|r")
                                    end
                                end
                            end, detectedLang)
                            
                            if apiQueued and replacePendingData then
                                replacePendingKey = "r|" .. tostring(capturedThis) .. "|" .. capturedArg1
                                replacePendingData.timestamp = GetTime()
                                pendingMessages[replacePendingKey] = replacePendingData
                            end
                        end)
                        if not _ok then DebugLog("OnEvent 挂钩错误:", tostring(_err)) end
                    end)

                    DebugLog("已挂钩聊天框架", frameName)
                end
            end

        end
    end
end

-- 清理超时未翻译的消息，恢复显示原文
local function CleanupPendingMessages()
    local now = GetTime()
    for msgId, pending in pairs(pendingMessages) do
        if now - pending.timestamp > 30 then
            DebugLog("消息超时:", msgId)
            pending.originalAddMessage(pending.frame, pending.originalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
            pendingMessages[msgId] = nil
        end
    end
end

-- ============================================================================
-- 发送消息翻译（英文 → 中文）
-- ============================================================================

-- 清理超时的发送队列
local function CleanupOutgoingQueue()
    local now = GetTime()
    for queueId, item in pairs(outgoingQueue) do
        if now - item.timestamp > 30 then
            DebugLog("发送消息超时:", queueId)
            if originalAddMessage then
                originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFF0000[WoWTranslate] 翻译超时，发送原文|r")
            end
            originalSendChatMessage(item.originalMsg, item.chatType, item.language, item.channel)
            outgoingQueue[queueId] = nil
        end
    end
end

-- 挂钩发送消息函数，实现发送翻译
local function HookedSendChatMessage(msg, chatType, language, channel)
    -- 兼容魔兽 1.12 空频道类型
    if not chatType then
        DebugLog("chatType 为空，直接发送原文")
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 发送翻译未启用，直接发送
    if not WoWTranslateDB or not WoWTranslateDB.outgoingEnabled then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- AFK 时不翻译
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 频道未启用发送翻译
    if not WoWTranslateDB.outgoingChannels then
        DebugLog("该频道未启用发送翻译:", chatType)
        return originalSendChatMessage(msg, chatType, language, channel)
    end
    local effectiveOutChannel = chatType
    if chatType == "CHANNEL" and channel then
        local list = {GetChannelList()}
        for i = 1, table.getn(list), 2 do
            if list[i] == channel then
                if string.find(string.lower(list[i+1] or ""), "^english") then
                    effectiveOutChannel = "ENGLISH"
                end
                break
            end
        end
    end
    if not WoWTranslateDB.outgoingChannels[effectiveOutChannel] then
        DebugLog("该频道未启用发送翻译:", effectiveOutChannel)
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 空消息不处理
    if not msg or msg == "" then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 跳过宏命令
    if string.sub(msg, 1, 1) == "#" then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 跳过插件命令
    if string.sub(msg, 1, 1) == "." then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 跳过插件内部通信消息
    if string.find(msg, "^[A-Za-z][A-Za-z0-9_]*:%d+:") then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 已包含目标语言，不重复翻译
    if ContainsOutgoingTargetLanguage(msg) then
        DebugLog("消息已包含目标语言，跳过发送翻译")
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 翻译核心未加载
    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        DebugLog("翻译核心未加载，无法发送翻译")
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- 分割消息，保留超链接
    local segments = SplitIntoSegments(msg)
    DebugLog("发送段数:", table.getn(segments))

    -- 构建待翻译文本
    local textToTranslate = BuildTranslatableText(segments)
    DebugLog("待发送翻译文本:", textToTranslate)

    -- 应用对应方向的词汇表
    local outFromLang = WoWTranslateDB.outgoingFromLang or "en"
    if outFromLang == "en" then
        -- 英文→中文：货币格式转换 + 外向词汇表
        textToTranslate = PreprocessOutgoing(textToTranslate)
        if WoWTranslate_CheckOutGlossaryExact then
            local glossaryResult = WoWTranslate_CheckOutGlossaryExact(textToTranslate)
            if not glossaryResult and WoWTranslate_CheckOutGlossaryPartial then
                glossaryResult = WoWTranslate_CheckOutGlossaryPartial(textToTranslate)
            end
            if glossaryResult then
                DebugLog("已应用外向词汇表（英→中）:", glossaryResult)
                textToTranslate = glossaryResult
            end
        end
    else
        -- 中文→英文：应用内向词汇表
        if WoWTranslate_CheckGlossaryExact then
            local glossaryResult = WoWTranslate_CheckGlossaryExact(textToTranslate)
            if not glossaryResult and WoWTranslate_CheckGlossaryPartial then
                glossaryResult = WoWTranslate_CheckGlossaryPartial(textToTranslate)
            end
            if glossaryResult then
                DebugLog("已应用外向词汇表（中→英）:", glossaryResult)
                textToTranslate = glossaryResult
            end
        end
    end

    -- 加入翻译队列
    outgoingCounter = outgoingCounter + 1
    local queueId = tostring(outgoingCounter)

    outgoingQueue[queueId] = {
        originalMsg = msg,
        segments = segments,
        chatType = chatType,
        language = language,
        channel = channel,
        timestamp = GetTime()
    }

-- 显示本地提示
if originalAddMessage then
    originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFFFF00[WoWTranslate] 正在翻译...|r")
end

DebugLog("发送消息已加入队列:", queueId, msg)

-- 请求翻译（仅发送文本部分，不包含超链接）
WoWTranslate_API.TranslateOutgoing(textToTranslate, function(translation, err)
    local queued = outgoingQueue[queueId]
    if not queued then
        DebugLog("发送回调：队列项已消失:", queueId)
        return
    end
    outgoingQueue[queueId] = nil

    if translation then
        DebugLog("收到发送翻译结果:", translation)

        -- 结合原始超链接重建消息
        local reconstructed = ReconstructMessage(queued.segments, translation)
        DebugLog("发送消息重建完成:", reconstructed)

        -- 构建最终消息，可选添加前缀
        local finalMsg
        if WoWTranslateDB.outgoingPrefixEnabled then
            local userPrefix = WoWTranslateDB.outgoingPrefix or DEFAULT_PREFIX
            local prefix
            if userPrefix == DEFAULT_PREFIX then
                local targetLang = WoWTranslateDB.outgoingToLang or "zh"
                prefix = TRANSLATED_PREFIXES[targetLang] or userPrefix
            else
                prefix = userPrefix
            end
            finalMsg = prefix .. " " .. reconstructed
        else
            finalMsg = reconstructed
        end

        -- 超过255字节自动截断（魔兽聊天限制）
        if string.len(finalMsg) > 255 then
            finalMsg = string.sub(finalMsg, 1, 252) .. "..."
        end

        originalSendChatMessage(finalMsg, queued.chatType, queued.language, queued.channel)

        if originalAddMessage then
            originalAddMessage(DEFAULT_CHAT_FRAME, "|cFF00FF00[WoWTranslate] 已发送:|r " .. finalMsg)
        end
    else
        -- 翻译失败，发送原文
        DebugLog("发送翻译失败:", err)
        if originalAddMessage then
            originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFF0000[WoWTranslate] 翻译失败，已发送原文|r")
        end
        originalSendChatMessage(queued.originalMsg, queued.chatType, queued.language, queued.channel)
    end
end)
end

-- 记录挂钩状态（用于诊断）
local outgoingHookInstalled = false

-- 安装发送消息挂钩
local function InstallOutgoingHook()
    if SendChatMessage ~= HookedSendChatMessage then
        DebugLog("正在安装发送消息挂钩")
        SendChatMessage = HookedSendChatMessage
        outgoingHookInstalled = true
    end
end

-- 移除发送消息挂钩
local function RemoveOutgoingHook()
    if SendChatMessage == HookedSendChatMessage then
        DebugLog("正在移除发送消息挂钩")
        SendChatMessage = originalSendChatMessage
        outgoingHookInstalled = false
    end
end

-- 检查挂钩是否激活（用于诊断）
local function IsOutgoingHookActive()
    return outgoingHookInstalled and SendChatMessage == HookedSendChatMessage
end

-- ============================================================================
-- 设置界面全局函数
-- ============================================================================

-- 切换发送翻译（设置界面/按钮调用）
function WoWTranslate_SetOutgoingEnabled(enabled)
    if enabled then
        WoWTranslateDB.outgoingEnabled = true
        InstallOutgoingHook()
    else
        WoWTranslateDB.outgoingEnabled = false
        RemoveOutgoingHook()
    end
    UpdateOutgoingButton()
end

function WoWTranslate_SetOutgoingButtonVisible(enabled)
    if WoWTranslateDB then WoWTranslateDB.showOutgoingButton = enabled end
    ApplyOutgoingButtonVisibility()
end

-- 切换接收翻译（设置界面调用）
function WoWTranslate_SetIncomingEnabled(enabled)
    WoWTranslateDB.enabled = enabled
end

-- 设置发送频道启用状态（设置界面调用）
function WoWTranslate_SetChannelEnabled(channel, enabled)
    if not WoWTranslateDB.outgoingChannels then
        WoWTranslateDB.outgoingChannels = {}
    end
    WoWTranslateDB.outgoingChannels[channel] = enabled
end

-- 设置接收频道启用状态（设置界面调用）
function WoWTranslate_SetIncomingChannelEnabled(channel, enabled)
    if not WoWTranslateDB.incomingChannels then
        WoWTranslateDB.incomingChannels = {}
    end
    WoWTranslateDB.incomingChannels[channel] = enabled
end

-- ============================================================================
-- 斜杠命令
-- ============================================================================
SLASH_WOWTRANSLATE1 = "/wt"
SLASH_WOWTRANSLATE2 = "/wowtranslate"

SlashCmdList["WOWTRANSLATE"] = function(msg)
    if not WoWTranslateDB then
        WoWTranslateDB = {}
        InitializeSettings()
    end

    local cmd, arg = strsplit(" ", msg, 2)
    cmd = string.lower(cmd or "")

    if cmd == "on" or cmd == "enable" then
        WoWTranslateDB.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] 已启用接收翻译|r")

    elseif cmd == "off" or cmd == "disable" then
        WoWTranslateDB.enabled = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 已禁用接收翻译|r")

    elseif cmd == "status" then
        local dllStatus = WoWTranslate_API.IsAvailable()
            and "|cFF00FF00已连接|r"
            or "|cFFFF0000未加载|r"

        local cacheStats = WoWTranslate_CacheStats()
        local glossaryCount = WoWTranslate_GetGlossaryCount()
        local pendingCount = WoWTranslate_API.GetPendingCount()

        local queuedCount = 0
        for _ in pairs(pendingMessages) do
            queuedCount = queuedCount + 1
        end

        local outgoingQueuedCount = 0
        for _ in pairs(outgoingQueue) do
            outgoingQueuedCount = outgoingQueuedCount + 1
        end

        local outgoingStatus = WoWTranslateDB.outgoingEnabled
            and "|cFF00FF00开启|r"
            or "|cFFFF0000关闭|r"

        local hookStatus = IsOutgoingHookActive()
            and "|cFF00FF00已激活|r"
            or "|cFFFF0000未激活|r"

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 状态信息:")
        DEFAULT_CHAT_FRAME:AddMessage("  翻译核心: " .. dllStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  接收翻译: " .. (WoWTranslateDB.enabled and "|cFF00FF00开启|r" or "|cFFFF0000关闭|r"))
        DEFAULT_CHAT_FRAME:AddMessage("  发送翻译: " .. outgoingStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  发送挂钩: " .. hookStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  词汇表条目: " .. glossaryCount)
        DEFAULT_CHAT_FRAME:AddMessage("  缓存翻译数: " .. cacheStats.entries)
        DEFAULT_CHAT_FRAME:AddMessage("  缓存命中率: " .. string.format("%.1f%%", cacheStats.hitRate))
        DEFAULT_CHAT_FRAME:AddMessage("  等待API请求: " .. pendingCount)
        DEFAULT_CHAT_FRAME:AddMessage("  接收队列: " .. queuedCount)
        DEFAULT_CHAT_FRAME:AddMessage("  发送队列: " .. outgoingQueuedCount)
        local cbErr = WoWTranslate_API.GetLastCallbackError and WoWTranslate_API.GetLastCallbackError()
        if cbErr then
            DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF4444上次回调错误:|r " .. cbErr)
        end
        local rlActive, rlRemaining = WoWTranslate_API.GetRateLimitInfo()
        if rlActive then
            DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF4444API冷却中:|r " .. rlRemaining .. "秒后恢复 (输入 /wt reset 清除)|r")
        end

    elseif cmd == "test" then
        local testText = arg or "你好"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 测试翻译: " .. testText)

        local cached, found = WoWTranslate_CacheGet(testText)
        if found then
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 缓存命中: " .. cached)
            return
        end

        if not WoWTranslate_API.IsAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 翻译核心未加载|r")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 正在请求API翻译...")
        WoWTranslate_API.Translate(testText, function(result, err)
            if result then
                DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] API结果: " .. result)
                WoWTranslate_CacheSave(testText, result)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] API错误: " .. (err or "未知错误") .. "|r")
            end
        end)

    elseif cmd == "clearcache" then
        WoWTranslate_CacheClear()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate] 已清空翻译缓存|r")

    elseif cmd == "debug" then
        DEBUG_MODE = not DEBUG_MODE
        WoWTranslateDB.debugMode = DEBUG_MODE
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 调试模式: " .. (DEBUG_MODE and "|cFF00FF00开启|r" or "|cFFFF0000关闭|r"))

    elseif cmd == "log" then
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 最近日志:")
        local logs = WoWTranslateDebugLog or {}
        local start = math.max(1, table.getn(logs) - 19)
        for i = start, table.getn(logs) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. logs[i])
        end

    elseif cmd == "clearlog" then
        WoWTranslateDebugLog = {}
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 已清空调试日志")

    elseif cmd == "testlink" then
        -- 测试超链接解析与本地化
        local testMsg = "|cffffffff|Hplayer:TestName|h[TestName]|h|r 说你好"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 测试超链接解析:")
        DEFAULT_CHAT_FRAME:AddMessage("  输入: " .. testMsg)
        local segs = SplitIntoSegments(testMsg)
        for idx, seg in ipairs(segs) do
            DEFAULT_CHAT_FRAME:AddMessage("  分段 " .. idx .. " [" .. seg.type .. "]: " .. seg.content)
        end

    elseif cmd == "testitem" then
        -- 测试物品本地化
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 测试物品本地化...")
        local itemId = 2589  -- 默认：亚麻布
        if arg and arg ~= "" then
            itemId = tonumber(arg) or 19716
        end
        DEFAULT_CHAT_FRAME:AddMessage("  物品ID: " .. tostring(itemId))
        local itemName = GetItemInfo(itemId)
        if itemName then
            DEFAULT_CHAT_FRAME:AddMessage("  物品名称: " .. itemName)
            local testLink = "|cffa335ee|Hitem:" .. itemId .. ":0:0:0|h[测试物品]|h|r"
            DEFAULT_CHAT_FRAME:AddMessage("  测试链接: " .. testLink)
            local localized = LocalizeHyperlink(testLink)
            DEFAULT_CHAT_FRAME:AddMessage("  本地化后: " .. localized)
        else
            DEFAULT_CHAT_FRAME:AddMessage("  物品未缓存 - 先鼠标指向物品链接再试")
        end

    elseif cmd == "testquest" then
        -- 测试任务本地化（需要pfQuest）
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 测试任务本地化...")
        local questId = 913
        if arg and arg ~= "" then
            questId = tonumber(arg) or 913
        end
        DEFAULT_CHAT_FRAME:AddMessage("  任务ID: " .. tostring(questId))

        if not pfDB or not pfDB["quests"] then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000  未找到pfQuest数据库|r")
            return
        end

        local questName = GetEnglishQuestName(questId)
        if questName then
            DEFAULT_CHAT_FRAME:AddMessage("  任务名称: " .. questName)
            local testLink = "|cffffff00|Hquest:" .. questId .. ":60|h[测试任务]|h|r"
            DEFAULT_CHAT_FRAME:AddMessage("  测试链接: " .. testLink)
            local localized = LocalizeHyperlink(testLink)
            DEFAULT_CHAT_FRAME:AddMessage("  本地化后: " .. localized)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000  数据库中未找到该任务|r")
        end

    -- =====================================================================
    -- 发送翻译命令
    -- =====================================================================
    elseif cmd == "outgoing" then
        if arg == "on" or arg == "enable" then
            WoWTranslate_SetOutgoingEnabled(true)
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] 已启用发送翻译|r")
        elseif arg == "off" or arg == "disable" then
            WoWTranslate_SetOutgoingEnabled(false)
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 已禁用发送翻译|r")
        else
            -- 无参数：切换
            WoWTranslate_SetOutgoingEnabled(not WoWTranslateDB.outgoingEnabled)
            local status = WoWTranslateDB.outgoingEnabled and "|cFF00FF00开启|r" or "|cFFFF0000关闭|r"
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 发送翻译: " .. status)
        end

    elseif cmd == "outchannel" then
        if not WoWTranslateDB.outgoingChannels then
            WoWTranslateDB.outgoingChannels = defaults.outgoingChannels
        end

        if arg and arg ~= "" then
            local channelType = string.upper(arg)
            if WoWTranslateDB.outgoingChannels[channelType] ~= nil then
                WoWTranslateDB.outgoingChannels[channelType] = not WoWTranslateDB.outgoingChannels[channelType]
                local newStatus = WoWTranslateDB.outgoingChannels[channelType] and "|cFF00FF00开启|r" or "|cFFFF0000关闭|r"
                DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 发送频道 " .. channelType .. ": " .. newStatus)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 未知频道: " .. channelType .. "|r")
                DEFAULT_CHAT_FRAME:AddMessage("  支持频道: WHISPER, PARTY, GUILD, RAID, SAY, YELL, BATTLEGROUND, CHANNEL")
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 发送频道设置:")
            for channelType, enabled in pairs(WoWTranslateDB.outgoingChannels) do
                local status = enabled and "|cFF00FF00开启|r" or "|cFFFF0000关闭|r"
                DEFAULT_CHAT_FRAME:AddMessage("  " .. channelType .. ": " .. status)
            end
            DEFAULT_CHAT_FRAME:AddMessage("  用法: /wt outchannel <频道类型>")
        end

    elseif cmd == "prefix" then
        if arg and arg ~= "" then
            WoWTranslateDB.outgoingPrefix = arg
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 发送前缀已设置为: " .. arg)
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 当前前缀: " .. (WoWTranslateDB.outgoingPrefix or "[翻译完成]"))
            DEFAULT_CHAT_FRAME:AddMessage("  用法: /wt prefix <文字>")
        end

    elseif cmd == "testout" then
        local testText = arg or "Hello, how are you?"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 测试发送翻译:")
        DEFAULT_CHAT_FRAME:AddMessage("  输入: " .. testText)

        if not WoWTranslate_API.IsAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 翻译核心未加载|r")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 正在请求API...")
        WoWTranslate_API.TranslateOutgoing(testText, function(result, err)
            if result then
                DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] 翻译结果:|r " .. result)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 错误: " .. (err or "未知错误") .. "|r")
            end
        end)

    -- =====================================================================
    -- 设置界面命令
    -- =====================================================================
    elseif cmd == "reset" then
        -- 完全重置：重新挂钩、清除API状态
        local cleared = WoWTranslate_API.GetPendingCount()
        WoWTranslate_API.ClearPending()
        WoWTranslate_API.ResetBackoff()
        dllWarnShown = false
        translationErrWarnShown = false
        HookChatFrames(true)
        local ok = WoWTranslate_API.CheckDLL()
        if ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] 重置成功 — 已重新安装挂钩、核心正常、清除 " .. cleared .. " 个过期请求|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] 重置完成，但核心未响应 — 请输入 /reload|r")
        end

    elseif cmd == "hooktest" then
        -- 检查聊天框架挂钩状态
        local hookedCount = 0
        local totalFrames = 0
        for i = 1, NUM_CHAT_WINDOWS do
            local f = getglobal("ChatFrame" .. i)
            if f then
                totalFrames = totalFrames + 1
                if f.WoWTranslateHooked then
                    hookedCount = hookedCount + 1
                end
            end
        end

        if hookedCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF4444[挂钩检测] 无框架被挂钩 (0/" .. totalFrames .. ")|r")
        elseif hookedCount < totalFrames then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8800[挂钩检测] 部分挂钩: " .. hookedCount .. "/" .. totalFrames .. "|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[挂钩检测] 全部 " .. hookedCount .. "/" .. totalFrames .. " 个框架已正常挂钩|r")
        end
        DEFAULT_CHAT_FRAME:AddMessage("[挂钩检测] 挂钩调用次数: " .. tostring(hookCallCount))
        if hookCallCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8800[挂钩检测] 次数=0：已安装但未触发事件|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[挂钩检测] 挂钩工作正常|r")
        end

    elseif cmd == "show" or cmd == "config" or cmd == "options" then
        WoWTranslate_ShowConfig()

    elseif cmd == "hide" then
        WoWTranslate_HideConfig()

    else
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] 命令列表:")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt show - 打开设置面板")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt hide - 关闭设置面板")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt on|off - 启用/禁用接收翻译")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt status - 查看状态")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt reset - 翻译失效时重置")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt clearcache - 清空缓存")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt debug - 切换调试模式")
        DEFAULT_CHAT_FRAME:AddMessage("  -- 发送翻译 --")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt outgoing - 切换发送翻译")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt outchannel [类型] - 设置发送频道")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt prefix <文字> - 设置消息前缀")
    end
end

-- ============================================================================
-- 插件初始化
-- ============================================================================
local function InitializeSettings()
    if not WoWTranslateDB then WoWTranslateDB = {} end
    if not WoWTranslateDebugLog then WoWTranslateDebugLog = {} end
    if type(WoWTranslateCache) ~= "table" then WoWTranslateCache = {} end

    for key, value in pairs(defaults) do
        if WoWTranslateDB[key] == nil then
            WoWTranslateDB[key] = value
        end
    end

    -- 旧配置迁移
    if WoWTranslateDB.outgoingPrefix == "[Translated]" then
        WoWTranslateDB.outgoingPrefix = "[Translated by WoWTranslate]"
    end

    -- 新增频道配置补全
    if WoWTranslateDB.outgoingChannels then
        if WoWTranslateDB.outgoingChannels.BATTLEGROUND == nil then
            WoWTranslateDB.outgoingChannels.BATTLEGROUND = true
        end
        if WoWTranslateDB.outgoingChannels.CHANNEL == nil then
            WoWTranslateDB.outgoingChannels.CHANNEL = true
        end
        if WoWTranslateDB.outgoingChannels.HARDCORE == nil then
            WoWTranslateDB.outgoingChannels.HARDCORE = false
        end
        if WoWTranslateDB.outgoingChannels.ENGLISH == nil then
            WoWTranslateDB.outgoingChannels.ENGLISH = false
        end
    end

    -- 接收频道初始化
    if not WoWTranslateDB.incomingChannels then
        WoWTranslateDB.incomingChannels = {}
        for k, v in pairs(defaults.incomingChannels) do
            WoWTranslateDB.incomingChannels[k] = v
        end
    end
    if WoWTranslateDB.incomingChannels.HARDCORE == nil then
        WoWTranslateDB.incomingChannels.HARDCORE = false
    end
    if WoWTranslateDB.incomingChannels.ENGLISH == nil then
        WoWTranslateDB.incomingChannels.ENGLISH = false
    end

    if WoWTranslateDB.translationColorFollow == nil then
        WoWTranslateDB.translationColorFollow = false
    end

    DEBUG_MODE = WoWTranslateDB.debugMode or false

    -- 移除废弃配置
    WoWTranslateDB.apiKey = nil
    WoWTranslateDB.incomingFromLang = nil

    -- 语言配置补全
    if WoWTranslateDB.enabledSourceLangs == nil then
        WoWTranslateDB.enabledSourceLangs = { zh=true, ja=true, ko=true, ru=true }
    end
    if WoWTranslateDB.enabledSourceLangs.en == nil then
        WoWTranslateDB.enabledSourceLangs.en = false
    end

    -- 名字/公会翻译配置
    if WoWTranslateDB.translatePlayerNames == nil then
        WoWTranslateDB.translatePlayerNames = false
    end
    if WoWTranslateDB.translateGuildNames == nil then
        WoWTranslateDB.translateGuildNames = false
    end
    if WoWTranslateDB.translateNameplates == nil then
        WoWTranslateDB.translateNameplates = false
    end
    if WoWTranslateDB.translateGroupFinder == nil then
        WoWTranslateDB.translateGroupFinder = false
    end
    if WoWTranslateDB.manualTranslateEnabled == nil then
        WoWTranslateDB.manualTranslateEnabled = true
    end
    if WoWTranslateDB.manualTranslateShowLinks == nil then
        WoWTranslateDB.manualTranslateShowLinks = true
    end
    if WoWTranslateDB.outgoingButtonPos == nil then
        WoWTranslateDB.outgoingButtonPos = { x = 100, y = 100 }
    end
    if WoWTranslateDB.showOutgoingButton == nil then
        WoWTranslateDB.showOutgoingButton = true
    end
    EnsureManualTranslateStore()
    TrimManualTranslateStore()
end

local function OnAddonLoaded()
    if addonLoaded then return end
    addonLoaded = true

    InitializeSettings()

    if WoWTranslate_MinimapButton_Init then
        pcall(WoWTranslate_MinimapButton_Init)
    end

    HookTooltips()
    CreateOutgoingButton()

    local dllOk = WoWTranslate_API.CheckDLL()

    local glossaryCount = WoWTranslate_GetGlossaryCount()
    local cacheCount = WoWTranslate_CacheStats().entries
    local dllStatus = dllOk and "|cFF00FF00核心正常|r" or "|cFFFFFF00核心未加载|r"

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFWoWTranslate|r v1.5 - " .. dllStatus .. " | 输入 /wt show 打开设置")
end

-- ============================================================================
-- 玩家名字翻译（Shift+右键点击聊天名字）
-- ============================================================================
local function HookHyperlinkShow()
    local origHyperlink = ChatFrame_OnHyperlinkShow
    if not origHyperlink then return end

    ChatFrame_OnHyperlinkShow = function(link, text, button)
        local capturedFrame = this
        local _, _, manualId = string.find(link or "", "^wtmsg:(%d+)")
        if manualId then
            TranslateManualMessageById(manualId, capturedFrame or manualTranslateFrames[tostring(manualId)] or DEFAULT_CHAT_FRAME)
            return
        end
        if button == "RightButton" and IsShiftKeyDown() then
            local _, _, playerName = string.find(link, "^player:(.+)")
            if playerName and playerName ~= ""
               and WoWTranslate_API and WoWTranslate_API.IsAvailable() then
                local sent = WoWTranslate_API.Translate(playerName,
                    function(translation, err)
                        local frame = capturedFrame or DEFAULT_CHAT_FRAME
                        if translation and translation ~= "" and translation ~= playerName then
                            frame:AddMessage("|cFF00CCFF[WT]|r: " .. playerName .. " = " .. translation)
                        elseif err then
                            frame:AddMessage("|cFFFFFF00[WT]: 名字翻译失败: " .. tostring(err) .. "|r")
                        end
                    end, "auto")
                if sent then return end
            end
        end
        origHyperlink(link, text, button)
    end
end

local function OnPlayerLogin()
    HookChatFrames()
    HookHyperlinkShow()
    HookTooltips()

    if not WoWTranslate_API.IsAvailable() then
        WoWTranslate_API.CheckDLL()
    end

    -- 启用时安装发送挂钩
    if WoWTranslateDB and WoWTranslateDB.outgoingEnabled then
        InstallOutgoingHook()
    end

    -- 启用时安装组队查找器挂钩
    if WoWTranslateDB and WoWTranslateDB.translateGroupFinder then
        HookLFT()
    end
end

-- ============================================================================
-- 事件框架
-- ============================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_FLAGS_CHANGED")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and (arg1 == "WoWTranslate" or arg1 == "WoWTranslate_ManualSingle") then
        OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        OnPlayerLogin()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 切图/重载后重新检查核心
        if not WoWTranslate_API.IsAvailable() then
            WoWTranslate_API.CheckDLL()
        end
    elseif event == "PLAYER_FLAGS_CHANGED" and arg1 == "player" then
        if UnitIsAFK then
            playerIsAFK = (UnitIsAFK("player") == 1) or (UnitIsAFK("player") == true)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        if arg1 and string.find(arg1, "You are now AFK") then
            playerIsAFK = true
        elseif arg1 and string.find(arg1, "You are no longer AFK") then
            playerIsAFK = false
        end
    end
end)

-- 定时清理队列
local cleanupFrame = CreateFrame("Frame")
local cleanupElapsed = 0
cleanupFrame:SetScript("OnUpdate", function()
    cleanupElapsed = cleanupElapsed + arg1
    if cleanupElapsed >= 5 then
        cleanupElapsed = 0
        CleanupPendingMessages()
        CleanupOutgoingQueue()
    end
end)

-- 挂钩守护进程：防止魔兽重置聊天框架事件
local hookWatchdogElapsed = 0
local hookWatchdogFrame = CreateFrame("Frame")
hookWatchdogFrame:SetScript("OnUpdate", function()
    hookWatchdogElapsed = hookWatchdogElapsed + arg1
    if hookWatchdogElapsed >= 60 then
        hookWatchdogElapsed = 0
        pcall(HookChatFrames, true)
    end
end)

-- ============================================================================
-- 物品缓存轮询
-- ============================================================================
local function ProcessItemCacheMessage(queued)
    local text = queued.text
    local detectedLang = DetectSourceLanguage(text) or "zh"

    local headerText, msgBody = SplitHeaderAndMessage(text)
    local segments = SplitIntoSegments(msgBody)

    DebugLog("处理物品缓存消息，分段数:", table.getn(segments))

    if not HasTranslatableContent(segments) then
        local result = headerText
        for _, seg in ipairs(segments) do
            result = result .. seg.content
        end
        queued.originalAddMessage(queued.frame, result, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
        return
    end

    local textToTranslate = BuildTranslatableText(segments)

    local cached, found = WoWTranslate_CacheGet(msgBody)
    if found then
        DebugLog("物品消息缓存命中")
        local finalText = headerText .. ReconstructMessage(segments, cached)
        queued.originalAddMessage(queued.frame, finalText, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
        return
    end

    if WoWTranslate_API and WoWTranslate_API.IsAvailable() then
        DebugLog("请求物品消息翻译")
        messageCounter = messageCounter + 1
        local msgId = tostring(messageCounter)
        pendingMessages[msgId] = {
            frame = queued.frame,
            originalAddMessage = queued.originalAddMessage,
            originalText = text,
            headerText = headerText,
            msgBody = msgBody,
            segments = segments,
            r = queued.r, g = queued.g, b = queued.b,
            id = queued.id, holdTime = queued.holdTime,
            timestamp = GetTime()
        }
        WoWTranslate_API.Translate(textToTranslate, function(translation, err)
            local pending = pendingMessages[msgId]
            if pending then
                pendingMessages[msgId] = nil
                if translation and translation ~= "" then
                    local finalText = pending.headerText .. ReconstructMessage(pending.segments, translation)
                    WoWTranslate_CacheSave(pending.msgBody, translation)
                    pcall(pending.originalAddMessage, pending.frame, finalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
                else
                    pcall(pending.originalAddMessage, pending.frame, pending.originalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
                end
            end
        end, detectedLang)
    else
        local result = headerText
        for _, seg in ipairs(segments) do result = result .. seg.content end
        queued.originalAddMessage(queued.frame, result, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
    end
end

local itemCacheFrame = CreateFrame("Frame")
local itemCacheElapsed = 0
local ITEM_CACHE_POLL_INTERVAL = 0.05
local ITEM_CACHE_MAX_WAIT = 3.0
local ITEM_CACHE_RETRY_INTERVAL = 0.5

itemCacheFrame:SetScript("OnUpdate", function()
    itemCacheElapsed = itemCacheElapsed + arg1
    if itemCacheElapsed < ITEM_CACHE_POLL_INTERVAL then
        return
    end
    itemCacheElapsed = 0

    for cacheId, queued in pairs(itemCacheQueue) do
        local allCached = CheckItemCache(queued.itemIds, false)
        local elapsed = GetTime() - queued.timestamp

        if allCached then
            DebugLog("物品已缓存，处理消息:", cacheId)
            itemCacheQueue[cacheId] = nil
            ProcessItemCacheMessage(queued)
        elseif elapsed > ITEM_CACHE_MAX_WAIT then
            DebugLog("物品缓存超时", elapsed, "秒")
            itemCacheQueue[cacheId] = nil
            ProcessItemCacheMessage(queued)
        else
            if not queued.lastRetry or (GetTime() - queued.lastRetry) > ITEM_CACHE_RETRY_INTERVAL then
                queued.lastRetry = GetTime()
                queued.retries = (queued.retries or 0) + 1
                if queued.retries <= 5 then
                    local _, stillUncached = CheckItemCache(queued.itemIds, true)
                end
            end
        end
    end
end)
