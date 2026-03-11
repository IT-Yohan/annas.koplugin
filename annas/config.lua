local util = require("util")
local logger = require("logger")
local T = require("annas.gettext")

local Config = {}

Config.SETTINGS_SEARCH_LANGUAGES_KEY = "annas_search_languages"
Config.SETTINGS_SEARCH_EXTENSIONS_KEY = "annas_search_extensions"
Config.SETTINGS_SEARCH_ORDERS_KEY = "annas_search_order"
Config.SETTINGS_DOWNLOAD_DIR_KEY = "annas_download_dir"
Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY = "annas_turn_off_wifi_after_download"
Config.SETTINGS_TIMEOUT_SEARCH_KEY = "annas_timeout_search"
Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY = "annas_timeout_download"
Config.SETTINGS_TIMEOUT_COVER_KEY = "annas_timeout_cover"
Config.SETTINGS_TEST_MODE_KEY = "annas_test_mode"

Config.LEGACY_SETTINGS = {
    [Config.SETTINGS_SEARCH_LANGUAGES_KEY] = "zlibrary_search_languages",
    [Config.SETTINGS_SEARCH_EXTENSIONS_KEY] = "zlibrary_search_extensions",
    [Config.SETTINGS_SEARCH_ORDERS_KEY] = "zlibrary_search_order",
    [Config.SETTINGS_DOWNLOAD_DIR_KEY] = "zlibrary_download_dir",
    [Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY] = "zlibrary_turn_off_wifi_after_download",
    [Config.SETTINGS_TIMEOUT_SEARCH_KEY] = "zlibrary_timeout_search",
    [Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY] = "zlibrary_timeout_download",
    [Config.SETTINGS_TIMEOUT_COVER_KEY] = "zlibrary_timeout_cover",
    [Config.SETTINGS_TEST_MODE_KEY] = "zlibrary_test_mode",
}

Config.OBSOLETE_SETTINGS = {
    "annas_base_url",
    "annas_username",
    "annas_password",
    "annas_user_id",
    "annas_user_key",
    "annas_timeout_login",
    "annas_timeout_book_details",
    "annas_timeout_recommended",
    "annas_timeout_popular",
    "zlibrary_base_url",
    "zlibrary_username",
    "zlibrary_password",
    "zlib_user_id",
    "zlib_user_key",
    "zlibrary_timeout_login",
    "zlibrary_timeout_book_details",
    "zlibrary_timeout_recommended",
    "zlibrary_timeout_popular",
}

local function readRawSetting(key)
    return G_reader_settings:readSetting(key)
end

Config.DEFAULT_DOWNLOAD_DIR_FALLBACK = G_reader_settings:readSetting("home_dir")
             or require("apps/filemanager/filemanagerutil").getDefaultDir()

Config.TIMEOUT_SEARCH = { 15, 15 }
Config.TIMEOUT_DOWNLOAD = { 15, -1 }
Config.TIMEOUT_COVER = { 5, 15 }

Config.SUPPORTED_LANGUAGES = {
    { name = "العربية", value = "arabic" },
    { name = "Հայերեն", value = "armenian" },
    { name = "Azərbaycanca", value = "azerbaijani" },
    { name = "বাংলা", value = "bengali" },
    { name = "简体中文", value = "chinese" },
    { name = "Nederlands", value = "dutch" },
    { name = "English", value = "en" },
    { name = "Français", value = "fr" },
    { name = "ქართული", value = "georgian" },
    { name = "Deutsch", value = "de" },
    { name = "Ελληνικά", value = "greek" },
    { name = "हिन्दी", value = "hindi" },
    { name = "Bahasa Indonesia", value = "indonesian" },
    { name = "Italiano", value = "italian" },
    { name = "日本語", value = "japanese" },
    { name = "한국어", value = "korean" },
    { name = "Bahasa Malaysia", value = "malaysian" },
    { name = "پښتو", value = "pashto" },
    { name = "Polski", value = "polish" },
    { name = "Português", value = "portuguese" },
    { name = "Русский", value = "russian" },
    { name = "Српски", value = "serbian" },
    { name = "Español", value = "sp" },
    { name = "తెలుగు", value = "telugu" },
    { name = "ไทย", value = "thai" },
    { name = "繁體中文", value = "traditional chinese" },
    { name = "Türkçe", value = "turkish" },
    { name = "Українська", value = "ukrainian" },
    { name = "اردو", value = "urdu" },
    { name = "Tiếng Việt", value = "vietnamese" },
}

Config.SUPPORTED_EXTENSIONS = {
    { name = "AZW", value = "AZW" },
    { name = "AZW3", value = "AZW3" },
    { name = "CBZ", value = "CBZ" },
    { name = "DJV", value = "DJV" },
    { name = "DJVU", value = "DJVU" },
    { name = "EPUB", value = "EPUB" },
    { name = "FB2", value = "FB2" },
    { name = "LIT", value = "LIT" },
    { name = "MOBI", value = "MOBI" },
    { name = "PDF", value = "PDF" },
    { name = "RTF", value = "RTF" },
    { name = "TXT", value = "TXT" },
}

Config.SUPPORTED_ORDERS = {
    { name = T("Most Relevant"), value = "" },
    { name = T("Newest"), value = "newest" },
    { name = T("Oldest"), value = "oldest" },
    { name = T("Largest"), value = "largest"},
    { name = T("Smallest"), value = "smallest"},
    { name = T("Newest Added"), value = "newest_added"},
    { name = T("Oldest Added"), value = "oldest_added"},
    { name = T("Random"), value = "random"}
}

function Config.getSetting(key, default)
    local value = readRawSetting(key)
    if value ~= nil then
        return value
    end

    local legacy_key = Config.LEGACY_SETTINGS[key]
    if legacy_key then
        local legacy_value = readRawSetting(legacy_key)
        if legacy_value ~= nil then
            Config.saveSetting(key, legacy_value)
            logger.info(string.format("Annas: migrated legacy setting %s to %s", legacy_key, key))
            return legacy_value
        end
    end

    return default
end

function Config.migrateLegacySettings()
    for key in pairs(Config.LEGACY_SETTINGS) do
        Config.getSetting(key)
    end
end

function Config.cleanupObsoleteSettings()
    for _, key in ipairs(Config.OBSOLETE_SETTINGS) do
        if readRawSetting(key) ~= nil then
            Config.deleteSetting(key)
            logger.info(string.format("Annas: removed obsolete setting %s", key))
        end
    end
end

function Config.saveSetting(key, value)
    if type(value) == "string" then
        G_reader_settings:saveSetting(key, util.trim(value))
    else
        G_reader_settings:saveSetting(key, value)
    end
end

function Config.deleteSetting(key)
    G_reader_settings:delSetting(key)
end

function Config.getDownloadDir()
    return Config.getSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, Config.DEFAULT_DOWNLOAD_DIR_FALLBACK)
end

function Config.getSearchLanguages()
    return Config.getSetting(Config.SETTINGS_SEARCH_LANGUAGES_KEY, {})
end

function Config.getSearchExtensions()
    return Config.getSetting(Config.SETTINGS_SEARCH_EXTENSIONS_KEY, {})
end

function Config.getSearchOrder()
    return Config.getSetting(Config.SETTINGS_SEARCH_ORDERS_KEY, {})
end

function Config.getSearchOrderName()
    local search_order_name = T("Default")
    local selected_order = Config.getSearchOrder()
    local search_order = selected_order and selected_order[1]

    if search_order then
        for _, v in ipairs(Config.SUPPORTED_ORDERS) do
            if v.value == search_order then
                search_order_name = v.name
                break
            end
        end
    end
    return search_order_name
end

function Config.getTurnOffWifiAfterDownload()
    return Config.getSetting(Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY, false)
end

function Config.setTurnOffWifiAfterDownload(turn_off)
    Config.saveSetting(Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY, turn_off)
end

function Config.isTestModeEnabled()
    return Config.getSetting(Config.SETTINGS_TEST_MODE_KEY, false)
end

function Config.setTestMode(enabled)
    Config.saveSetting(Config.SETTINGS_TEST_MODE_KEY, enabled)
end

-- Timeout configuration functions
function Config.getTimeoutConfig(timeout_key, default_timeout)
    local saved_timeout = Config.getSetting(timeout_key)
    if saved_timeout and type(saved_timeout) == "table" and #saved_timeout == 2 then
        return saved_timeout
    end
    return default_timeout
end

function Config.setTimeoutConfig(timeout_key, block_timeout, total_timeout)
    Config.saveSetting(timeout_key, {block_timeout, total_timeout})
end

function Config.getSearchTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_SEARCH_KEY, Config.TIMEOUT_SEARCH)
end

function Config.getDownloadTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY, Config.TIMEOUT_DOWNLOAD)
end

function Config.getCoverTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_COVER_KEY, Config.TIMEOUT_COVER)
end

function Config.formatTimeoutForDisplay(timeout_pair)
    local block_timeout = timeout_pair[1]
    local total_timeout = timeout_pair[2]
    
    local total_display = total_timeout == -1 and T("infinite") or (tostring(total_timeout) .. "s")
    return string.format(T("Block: %ds, Total: %s"), block_timeout, total_display)
end

function Config.setSearchTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_SEARCH_KEY, block_timeout, total_timeout)
end

function Config.setDownloadTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY, block_timeout, total_timeout)
end

function Config.setCoverTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_COVER_KEY, block_timeout, total_timeout)
end

return Config
