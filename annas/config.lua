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
Config.SETTINGS_MIRROR_STRATEGY_KEY = "annas_mirror_strategy"
Config.SETTINGS_RETRY_COUNT_KEY = "annas_retry_count"
Config.SETTINGS_TIMEOUT_POLICY_KEY = "annas_timeout_policy"
Config.SETTINGS_PREFERRED_SOURCE_KEY = "annas_preferred_source"
Config.SETTINGS_TEST_MODE_KEY = "annas_test_mode"
Config.SETTINGS_OTA_ENABLED_KEY = "annas_ota_enabled"
Config.SETTINGS_OTA_REPO_KEY = "annas_ota_repo"
Config.SETTINGS_OTA_CHANNEL_KEY = "annas_ota_channel"
Config.SETTINGS_OTA_ASSET_NAME_KEY = "annas_ota_asset_name"
Config.SETTINGS_OTA_TOKEN_KEY = "annas_ota_token"
Config.SETTINGS_OTA_ALLOW_ZIPBALL_KEY = "annas_ota_allow_zipball"

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

Config.TIMEOUT_POLICY_STANDARD = "standard"
Config.TIMEOUT_POLICY_RELAXED = "relaxed"
Config.TIMEOUT_POLICY_AGGRESSIVE = "aggressive"
Config.TIMEOUT_POLICY_CUSTOM = "custom"
Config.OTA_CHANNEL_STABLE = "stable"
Config.OTA_CHANNEL_PRERELEASE = "prerelease"
Config.DEFAULT_OTA_REPO = "fischer-hub/annas.koplugin"
Config.DEFAULT_OTA_ASSET_NAME = "annas.koplugin.zip"

Config.TIMEOUT_PROFILES = {
    [Config.TIMEOUT_POLICY_STANDARD] = {
        search = { 15, 15 },
        download = { 15, -1 },
        cover = { 5, 15 },
    },
    [Config.TIMEOUT_POLICY_RELAXED] = {
        search = { 25, 45 },
        download = { 25, -1 },
        cover = { 10, 20 },
    },
    [Config.TIMEOUT_POLICY_AGGRESSIVE] = {
        search = { 8, 12 },
        download = { 10, 60 },
        cover = { 4, 8 },
    },
}

Config.TIMEOUT_SEARCH = Config.TIMEOUT_PROFILES[Config.TIMEOUT_POLICY_STANDARD].search
Config.TIMEOUT_DOWNLOAD = Config.TIMEOUT_PROFILES[Config.TIMEOUT_POLICY_STANDARD].download
Config.TIMEOUT_COVER = Config.TIMEOUT_PROFILES[Config.TIMEOUT_POLICY_STANDARD].cover

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

Config.SUPPORTED_MIRROR_STRATEGIES = {
    { name = T("Automatic"), value = "auto" },
    { name = T("Rotate mirrors"), value = "rotate" },
    { name = T("Built-in mirrors first"), value = "builtin_first" },
}

Config.SUPPORTED_RETRY_COUNTS = {
    { name = T("Off"), value = 0 },
    { name = T("1 retry"), value = 1 },
    { name = T("2 retries"), value = 2 },
    { name = T("3 retries"), value = 3 },
}

Config.SUPPORTED_TIMEOUT_POLICIES = {
    { name = T("Standard"), value = Config.TIMEOUT_POLICY_STANDARD },
    { name = T("Relaxed"), value = Config.TIMEOUT_POLICY_RELAXED },
    { name = T("Aggressive"), value = Config.TIMEOUT_POLICY_AGGRESSIVE },
    { name = T("Custom"), value = Config.TIMEOUT_POLICY_CUSTOM },
}

Config.SUPPORTED_OTA_CHANNELS = {
    { name = T("Stable releases"), value = Config.OTA_CHANNEL_STABLE },
    { name = T("Include pre-releases"), value = Config.OTA_CHANNEL_PRERELEASE },
}

Config.SUPPORTED_PREFERRED_SOURCES = {
    { name = T("Automatic"), value = "auto" },
    { name = "libgen.la", value = "la" },
    { name = "libgen.gl", value = "gl" },
    { name = "libgen.li", value = "li" },
    { name = "libgen.is", value = "is" },
    { name = "libgen.rs", value = "rs" },
    { name = "libgen.st", value = "st" },
    { name = "libgen.bz", value = "bz" },
}

local function copyTimeoutPair(timeout_pair)
    return { timeout_pair[1], timeout_pair[2] }
end

local function findOptionName(options, value, fallback)
    for _, option in ipairs(options) do
        if option.value == value then
            return option.name
        end
    end

    return fallback
end

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

function Config.getMirrorStrategy()
    local value = Config.getSetting(Config.SETTINGS_MIRROR_STRATEGY_KEY, "auto")
    for _, option in ipairs(Config.SUPPORTED_MIRROR_STRATEGIES) do
        if option.value == value then
            return value
        end
    end

    return "auto"
end

function Config.getMirrorStrategyName()
    return findOptionName(Config.SUPPORTED_MIRROR_STRATEGIES, Config.getMirrorStrategy(), T("Automatic"))
end

function Config.setMirrorStrategy(value)
    Config.saveSetting(Config.SETTINGS_MIRROR_STRATEGY_KEY, value)
end

function Config.getRetryCount()
    local saved = tonumber(Config.getSetting(Config.SETTINGS_RETRY_COUNT_KEY, 1))
    if saved and saved >= 0 and saved <= 3 then
        return math.floor(saved)
    end

    return 1
end

function Config.getRetryCountName()
    return findOptionName(Config.SUPPORTED_RETRY_COUNTS, Config.getRetryCount(), T("1 retry"))
end

function Config.setRetryCount(value)
    Config.saveSetting(Config.SETTINGS_RETRY_COUNT_KEY, tonumber(value) or 1)
end

function Config.hasCustomTimeoutOverrides()
    return readRawSetting(Config.SETTINGS_TIMEOUT_SEARCH_KEY) ~= nil
        or readRawSetting(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY) ~= nil
        or readRawSetting(Config.SETTINGS_TIMEOUT_COVER_KEY) ~= nil
end

function Config.getTimeoutPolicy()
    local value = Config.getSetting(Config.SETTINGS_TIMEOUT_POLICY_KEY, Config.TIMEOUT_POLICY_STANDARD)
    if value == Config.TIMEOUT_POLICY_CUSTOM and not Config.hasCustomTimeoutOverrides() then
        return Config.TIMEOUT_POLICY_STANDARD
    end

    for _, option in ipairs(Config.SUPPORTED_TIMEOUT_POLICIES) do
        if option.value == value then
            return value
        end
    end

    return Config.TIMEOUT_POLICY_STANDARD
end

function Config.getTimeoutPolicyName()
    return findOptionName(Config.SUPPORTED_TIMEOUT_POLICIES, Config.getTimeoutPolicy(), T("Standard"))
end

function Config.setTimeoutPolicy(value)
    Config.saveSetting(Config.SETTINGS_TIMEOUT_POLICY_KEY, value)
end

function Config.applyTimeoutPolicy(value)
    Config.setTimeoutPolicy(value)
    Config.deleteSetting(Config.SETTINGS_TIMEOUT_SEARCH_KEY)
    Config.deleteSetting(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY)
    Config.deleteSetting(Config.SETTINGS_TIMEOUT_COVER_KEY)
end

function Config.markTimeoutPolicyCustom()
    Config.setTimeoutPolicy(Config.TIMEOUT_POLICY_CUSTOM)
end

function Config.getPreferredSource()
    local value = Config.getSetting(Config.SETTINGS_PREFERRED_SOURCE_KEY, "auto")
    for _, option in ipairs(Config.SUPPORTED_PREFERRED_SOURCES) do
        if option.value == value then
            return value
        end
    end

    return "auto"
end

function Config.getPreferredSourceName()
    return findOptionName(Config.SUPPORTED_PREFERRED_SOURCES, Config.getPreferredSource(), T("Automatic"))
end

function Config.setPreferredSource(value)
    Config.saveSetting(Config.SETTINGS_PREFERRED_SOURCE_KEY, value)
end

function Config.getOtaEnabled()
    return Config.getSetting(Config.SETTINGS_OTA_ENABLED_KEY, true)
end

function Config.setOtaEnabled(enabled)
    Config.saveSetting(Config.SETTINGS_OTA_ENABLED_KEY, enabled)
end

function Config.normalizeOtaRepo(value)
    local normalized = util.trim(tostring(value or ""))
    normalized = normalized:gsub("^https?://github%.com/", "")
    normalized = normalized:gsub("^git@github%.com:", "")
    normalized = normalized:gsub("%.git$", "")
    normalized = normalized:gsub("^/+", "")
    normalized = normalized:gsub("/+$", "")
    return normalized
end

function Config.validateOtaRepo(value)
    local normalized = Config.normalizeOtaRepo(value)
    if normalized == "" then
        return false, T("Repository cannot be empty.")
    end

    if not normalized:match("^[%w%._%-]+/[%w%._%-]+$") then
        return false, T("Repository must use the form owner/repo.")
    end

    return true, normalized
end

function Config.getOtaRepo()
    local value = Config.getSetting(Config.SETTINGS_OTA_REPO_KEY, Config.DEFAULT_OTA_REPO)
    local ok, normalized = Config.validateOtaRepo(value)
    if ok then
        return normalized
    end

    return Config.DEFAULT_OTA_REPO
end

function Config.setOtaRepo(value)
    local ok, normalized_or_error = Config.validateOtaRepo(value)
    if not ok then
        return false, normalized_or_error
    end

    Config.saveSetting(Config.SETTINGS_OTA_REPO_KEY, normalized_or_error)
    return true, normalized_or_error
end

function Config.getOtaChannel()
    local value = Config.getSetting(Config.SETTINGS_OTA_CHANNEL_KEY, Config.OTA_CHANNEL_STABLE)
    for _, option in ipairs(Config.SUPPORTED_OTA_CHANNELS) do
        if option.value == value then
            return value
        end
    end

    return Config.OTA_CHANNEL_STABLE
end

function Config.getOtaChannelName()
    return findOptionName(Config.SUPPORTED_OTA_CHANNELS, Config.getOtaChannel(), T("Stable releases"))
end

function Config.setOtaChannel(value)
    Config.saveSetting(Config.SETTINGS_OTA_CHANNEL_KEY, value)
end

function Config.getOtaAssetName()
    local value = util.trim(tostring(Config.getSetting(Config.SETTINGS_OTA_ASSET_NAME_KEY, Config.DEFAULT_OTA_ASSET_NAME) or ""))
    if value == "" then
        return Config.DEFAULT_OTA_ASSET_NAME
    end

    return value
end

function Config.setOtaAssetName(value)
    local normalized = util.trim(tostring(value or ""))
    if normalized == "" then
        Config.deleteSetting(Config.SETTINGS_OTA_ASSET_NAME_KEY)
        return
    end

    Config.saveSetting(Config.SETTINGS_OTA_ASSET_NAME_KEY, normalized)
end

function Config.getOtaToken()
    local value = Config.getSetting(Config.SETTINGS_OTA_TOKEN_KEY)
    if value == nil then
        return nil
    end

    value = util.trim(tostring(value))
    if value == "" then
        return nil
    end

    return value
end

function Config.setOtaToken(value)
    local normalized = util.trim(tostring(value or ""))
    if normalized == "" then
        Config.deleteSetting(Config.SETTINGS_OTA_TOKEN_KEY)
        return
    end

    Config.saveSetting(Config.SETTINGS_OTA_TOKEN_KEY, normalized)
end

function Config.hasOtaToken()
    return Config.getOtaToken() ~= nil
end

function Config.getOtaAllowZipball()
    return Config.getSetting(Config.SETTINGS_OTA_ALLOW_ZIPBALL_KEY, false)
end

function Config.setOtaAllowZipball(enabled)
    Config.saveSetting(Config.SETTINGS_OTA_ALLOW_ZIPBALL_KEY, enabled)
end

function Config.getTimeoutDefaults(kind)
    local policy = Config.getTimeoutPolicy()
    local profile = Config.TIMEOUT_PROFILES[policy] or Config.TIMEOUT_PROFILES[Config.TIMEOUT_POLICY_STANDARD]
    local timeout_pair = profile[kind] or Config.TIMEOUT_PROFILES[Config.TIMEOUT_POLICY_STANDARD][kind]
    return copyTimeoutPair(timeout_pair)
end

-- Timeout configuration functions
function Config.getTimeoutConfig(timeout_key, default_timeout)
    local saved_timeout = Config.getSetting(timeout_key)
    if saved_timeout and type(saved_timeout) == "table" and #saved_timeout == 2 then
        return saved_timeout
    end

    return copyTimeoutPair(default_timeout)
end

function Config.setTimeoutConfig(timeout_key, block_timeout, total_timeout)
    Config.saveSetting(timeout_key, {block_timeout, total_timeout})
    Config.markTimeoutPolicyCustom()
end

function Config.getSearchTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_SEARCH_KEY, Config.getTimeoutDefaults("search"))
end

function Config.getDownloadTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY, Config.getTimeoutDefaults("download"))
end

function Config.getCoverTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_COVER_KEY, Config.getTimeoutDefaults("cover"))
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
