local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local T = require("annas.gettext")
local DownloadMgr = require("ui/downloadmgr")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("annas.menu")
local util = require("util")
local logger = require("logger")
local Config = require("annas.config")
local Ota = require("annas.ota")
require('src.scraper')
require('src.update')
local Ui = {}

local _plugin_instance = nil

function Ui.setPluginInstance(plugin_instance)
    _plugin_instance = plugin_instance
end

local function _showAndTrackDialog(dialog)
    if _plugin_instance and _plugin_instance.dialog_manager then
        return _plugin_instance.dialog_manager:showAndTrackDialog(dialog)
    else
        UIManager:show(dialog)
        return dialog
    end
end

local function _closeAndUntrackDialog(dialog)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:closeAndUntrackDialog(dialog)
    else
        if dialog then
            UIManager:close(dialog)
        end
    end
end

local function _colon_concat(a, b)
    return a .. ": " .. b
end

function Ui.colonConcat(a, b)
    return _colon_concat(a, b)
end

local function _findOptionName(options, value, fallback)
    for _, option in ipairs(options) do
        if option.value == value then
            return option.name
        end
    end

    return fallback
end

local function _summarizeLanguageSelection()
    local selected_languages = Config.getSearchLanguages()
    if #selected_languages == 0 then
        return T("Any")
    end

    if #selected_languages == 1 then
        return _findOptionName(Config.SUPPORTED_LANGUAGES, selected_languages[1], selected_languages[1])
    end

    return string.format(T("%d selected"), #selected_languages)
end

local function _summarizeFormatSelection()
    local selected_extensions = Config.getSearchExtensions()
    if #selected_extensions == 0 then
        return T("Any")
    end

    if #selected_extensions == 1 then
        return _findOptionName(Config.SUPPORTED_EXTENSIONS, selected_extensions[1], selected_extensions[1])
    end

    return string.format(T("%d selected"), #selected_extensions)
end

local function _summarizeOtaToken()
    return Config.hasOtaToken() and T("Configured") or T("Not set")
end

local function _providerDisplayName(provider_key)
    if provider_key == "lgli" then
        return "LibGen"
    end

    if provider_key == "zlib" then
        return "Z-Library"
    end

    return provider_key
end

local function _extractProvidersFromBook(book_data)
    local providers = {}
    local seen = {}

    local function addProvider(provider_key)
        if provider_key and provider_key ~= "" and not seen[provider_key] then
            seen[provider_key] = true
            table.insert(providers, provider_key)
        end
    end

    if type(book_data.providers) == "table" then
        for _, provider_key in ipairs(book_data.providers) do
            addProvider(provider_key)
        end
    end

    local download_text = tostring(book_data.download or "")
    if download_text:find("lgli", 1, true) then
        addProvider("lgli")
    end
    if download_text:find("zlib", 1, true) then
        addProvider("zlib")
    end

    return providers
end

local function _deriveProviderLabel(book_data)
    if type(book_data.provider_label) == "string" and book_data.provider_label ~= "" then
        return book_data.provider_label
    end

    local providers = _extractProvidersFromBook(book_data)
    if #providers == 0 then
        return T("Unavailable")
    end

    local labels = {}
    for _, provider_key in ipairs(providers) do
        table.insert(labels, _providerDisplayName(provider_key))
    end

    return table.concat(labels, " + ")
end

local function _hasSupportedProvider(book_data)
    local providers = _extractProvidersFromBook(book_data)
    return #providers > 0
end

local function _showSingleChoiceDialog(parent_ui, title, options_list, selected_value, on_select)
    local choice_menu
    local menu_items = {}

    for i, option_info in ipairs(options_list) do
        menu_items[i] = {
            text = option_info.name,
            mandatory_func = function()
                return selected_value == option_info.value and "[X]" or "[ ]"
            end,
            callback = function()
                _closeAndUntrackDialog(choice_menu)
                if on_select then
                    on_select(option_info.value)
                end
            end,
            keep_menu_open = true,
        }
    end

    choice_menu = Menu:new{
        title = title,
        item_table = menu_items,
        parent = parent_ui,
        show_captions = true,
    }
    _showAndTrackDialog(choice_menu)
end

function Ui.showInfoMessage(text)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showInfoMessage(text)
    else
        UIManager:show(InfoMessage:new{ text = text })
    end
end

function Ui.showErrorMessage(text)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showErrorMessage(text)
    else
        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
    end
end

function Ui.showLoadingMessage(text)
    local message = InfoMessage:new{ text = text, timeout = 0 }
    UIManager:show(message)
    return message
end

function Ui.updateLoadingMessage(message_widget, text)
    if type(text) ~= "string" or text == "" then
        return message_widget
    end

    if not message_widget then
        return Ui.showLoadingMessage(text)
    end

    if message_widget.is_closed or message_widget.is_destroyed then
        return Ui.showLoadingMessage(text)
    end

    if message_widget._annas_last_text == text then
        return message_widget
    end

    local updated = false

    if type(message_widget.setText) == "function" then
        message_widget:setText(text)
        updated = true
    else
        local success = pcall(function()
            message_widget.text = text
            if type(message_widget.update) == "function" then
                message_widget:update()
            end
        end)
        updated = success
    end

    if updated then
        message_widget._annas_last_text = text
        return message_widget
    end

    return message_widget
end

function Ui.closeMessage(message_widget)
    if message_widget then
        if type(message_widget.close) == "function" then
            message_widget:close()
            -- Ensure complete screen refresh after closing the progress dialog
            -- Use setDirty with "full" to completely redraw the screen area
            UIManager:setDirty("all", "full")
        else
            UIManager:close(message_widget)
        end
    end
end

function Ui.showFullTextDialog(title, full_text)
    local dialog = TextViewer:new{
        title = title,
        text = full_text,
    }
    _showAndTrackDialog(dialog)
end

function Ui.showCoverDialog(title, img_path)
    local ImageViewer = require("ui/widget/imageviewer")
    local dialog = ImageViewer:new{
        file = img_path,
        modal = true,
        with_title_bar = false,
        buttons_visible = false,
        scale_factor = 0
    }
    _showAndTrackDialog(dialog)
end

function Ui.showSimpleMessageDialog(title, text)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            title = title,
            text = text,
            cancel_text = T("Close"),
            no_ok_button = true,
        })
    else
        local dialog = ConfirmBox:new{
            title = title,
            text = text,
            cancel_text = T("Close"),
            no_ok_button = true,
        }
        UIManager:show(dialog)
    end
end

function Ui.showDownloadDirectoryDialog(on_saved_callback)
    local current_dir = Config.getDownloadDir()
    DownloadMgr:new{
        title = T("Select Download Directory"),
        onConfirm = function(path)
            if path then
                Config.saveSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, path)
                Ui.showInfoMessage(string.format(T("Download directory set to: %s"), path))
                if on_saved_callback then
                    on_saved_callback(path)
                end
            else
                Ui.showErrorMessage(T("No directory selected."))
            end
        end,
    }:chooseDir(current_dir)
end

function Ui.showSettingsDialog(parent_ui)
    local full_source_path = debug.getinfo(1, "S").source
    if full_source_path:sub(1,1) == "@" then
        full_source_path = full_source_path:sub(2)
    end
    local foo, _ = util.splitFilePathName(full_source_path):gsub("/+", "/")
    local plugin_path, _ = foo:gsub("[\\/]annas[\\/]", "")

    local settings_parent = parent_ui and parent_ui.ui or (_plugin_instance and _plugin_instance.ui)
    local settings_menu

    local function refreshSettingsMenu()
        if settings_menu then
            settings_menu:updateItems(nil, true)
        end
    end

    settings_menu = Menu:new{
        title = T("Anna Settings"),
        subtitle = T("Persistent options used for search and download"),
        item_table = {
            {
                text = T("Search order"),
                mandatory_func = function()
                    return Config.getSearchOrderName()
                end,
                callback = function()
                    Ui.showOrdersSelectionDialog(settings_parent, refreshSettingsMenu)
                end,
            },
            {
                text = T("Search languages"),
                mandatory_func = _summarizeLanguageSelection,
                callback = function()
                    Ui.showLanguageSelectionDialog(settings_parent, refreshSettingsMenu)
                end,
            },
            {
                text = T("Search formats"),
                mandatory_func = _summarizeFormatSelection,
                callback = function()
                    Ui.showExtensionSelectionDialog(settings_parent, refreshSettingsMenu)
                end,
            },
            {
                text = T("Search source"),
                mandatory_func = function()
                    return Config.getSearchSourceName()
                end,
                callback = function()
                    _showSingleChoiceDialog(settings_parent, T("Search source"), Config.SUPPORTED_SEARCH_SOURCES, Config.getSearchSource(), function(value)
                        Config.setSearchSource(value)
                        refreshSettingsMenu()
                    end)
                end,
            },
            {
                text = T("Download directory"),
                mandatory_func = function()
                    return Config.getDownloadDir()
                end,
                callback = function()
                    Ui.showDownloadDirectoryDialog(refreshSettingsMenu)
                end,
            },
            {
                text = T("Turn off Wi-Fi after download"),
                mandatory_func = function()
                    return Config.getTurnOffWifiAfterDownload() and T("On") or T("Off")
                end,
                callback = function()
                    Config.setTurnOffWifiAfterDownload(not Config.getTurnOffWifiAfterDownload())
                    refreshSettingsMenu()
                end,
            },
            {
                text = T("Mirror strategy"),
                mandatory_func = function()
                    return Config.getMirrorStrategyName()
                end,
                callback = function()
                    _showSingleChoiceDialog(settings_parent, T("Mirror strategy"), Config.SUPPORTED_MIRROR_STRATEGIES, Config.getMirrorStrategy(), function(value)
                        Config.setMirrorStrategy(value)
                        refreshSettingsMenu()
                    end)
                end,
            },
            {
                text = T("Automatic retries"),
                mandatory_func = function()
                    return Config.getRetryCountName()
                end,
                callback = function()
                    _showSingleChoiceDialog(settings_parent, T("Automatic retries"), Config.SUPPORTED_RETRY_COUNTS, Config.getRetryCount(), function(value)
                        Config.setRetryCount(value)
                        refreshSettingsMenu()
                    end)
                end,
            },
            {
                text = T("Preferred download source"),
                mandatory_func = function()
                    return Config.getPreferredSourceName()
                end,
                callback = function()
                    _showSingleChoiceDialog(settings_parent, T("Preferred download source"), Config.SUPPORTED_PREFERRED_SOURCES, Config.getPreferredSource(), function(value)
                        Config.setPreferredSource(value)
                        refreshSettingsMenu()
                    end)
                end,
            },
            {
                text = T("Timeout policy"),
                mandatory_func = function()
                    return Config.getTimeoutPolicyName()
                end,
                callback = function()
                    local timeout_policy_options = {
                        Config.SUPPORTED_TIMEOUT_POLICIES[1],
                        Config.SUPPORTED_TIMEOUT_POLICIES[2],
                        Config.SUPPORTED_TIMEOUT_POLICIES[3],
                    }
                    _showSingleChoiceDialog(settings_parent, T("Timeout policy"), timeout_policy_options, Config.getTimeoutPolicy(), function(value)
                        local apply_policy = function()
                            Config.applyTimeoutPolicy(value)
                            Ui.showInfoMessage(T("Timeout policy updated."))
                            refreshSettingsMenu()
                        end

                        if Config.getTimeoutPolicy() == Config.TIMEOUT_POLICY_CUSTOM then
                            if _plugin_instance and _plugin_instance.dialog_manager then
                                _plugin_instance.dialog_manager:showConfirmDialog({
                                    text = T("Applying a timeout policy will replace the current custom timeout values. Continue?"),
                                    ok_text = T("Apply"),
                                    cancel_text = T("Cancel"),
                                    ok_callback = apply_policy,
                                })
                            else
                                apply_policy()
                            end
                        else
                            apply_policy()
                        end
                    end)
                end,
            },
            {
                text = T("Advanced timeout settings"),
                mandatory_func = function()
                    return Config.getTimeoutPolicyName()
                end,
                callback = function()
                    Ui.showAllTimeoutConfigDialog(settings_parent, refreshSettingsMenu)
                end,
            },
            {
                text = "---",
            },
            {
                text = T("OTA updates"),
                mandatory_func = function()
                    return Config.getOtaEnabled() and T("On") or T("Off")
                end,
                callback = function()
                    Config.setOtaEnabled(not Config.getOtaEnabled())
                    refreshSettingsMenu()
                end,
            },
            {
                text = T("OTA repository"),
                mandatory_func = function()
                    return Config.getOtaRepo()
                end,
                callback = function()
                    Ui.showGenericInputDialog(
                        T("OTA repository"),
                        Config.SETTINGS_OTA_REPO_KEY,
                        Config.getOtaRepo(),
                        false,
                        function(input_value)
                            local ok, result = Config.setOtaRepo(input_value)
                            if not ok then
                                Ui.showErrorMessage(result)
                                return false
                            end
                            refreshSettingsMenu()
                            return true
                        end
                    )
                end,
            },
            {
                text = T("OTA channel"),
                mandatory_func = function()
                    return Config.getOtaChannelName()
                end,
                callback = function()
                    _showSingleChoiceDialog(settings_parent, T("OTA channel"), Config.SUPPORTED_OTA_CHANNELS, Config.getOtaChannel(), function(value)
                        Config.setOtaChannel(value)
                        refreshSettingsMenu()
                    end)
                end,
            },
            {
                text = T("OTA asset name"),
                mandatory_func = function()
                    return Config.getOtaAssetName()
                end,
                callback = function()
                    Ui.showGenericInputDialog(
                        T("OTA asset name"),
                        Config.SETTINGS_OTA_ASSET_NAME_KEY,
                        Config.getOtaAssetName(),
                        false,
                        function(input_value)
                            Config.setOtaAssetName(input_value)
                            refreshSettingsMenu()
                            return true
                        end
                    )
                end,
            },
            {
                text = T("GitHub token"),
                mandatory_func = _summarizeOtaToken,
                callback = function()
                    Ui.showGenericInputDialog(
                        T("GitHub token"),
                        Config.SETTINGS_OTA_TOKEN_KEY,
                        Config.getOtaToken() or "",
                        true,
                        function(input_value)
                            Config.setOtaToken(input_value)
                            refreshSettingsMenu()
                            return true
                        end
                    )
                end,
            },
            {
                text = T("Allow source ZIP fallback"),
                mandatory_func = function()
                    return Config.getOtaAllowZipball() and T("On") or T("Off")
                end,
                callback = function()
                    Config.setOtaAllowZipball(not Config.getOtaAllowZipball())
                    refreshSettingsMenu()
                end,
            },
            {
                text = T("Check for updates"),
                callback = function()
                    if plugin_path then
                        Ota.startUpdateProcess(plugin_path)
                    else
                        logger.err("Annas: Plugin path not available for OTA update.")
                        Ui.showErrorMessage(T("Error: Plugin path not found. Cannot check for updates."))
                    end
                end,
            },
        },
        parent = settings_parent,
        show_captions = true,
    }
    _showAndTrackDialog(settings_menu)
end

local function _showMultiSelectionDialog(parent_ui, title, setting_key, options_list, ok_callback, is_single)
    local selected_values_table = Config.getSetting(setting_key, {})
    local selected_values_set = {}
    for _, value in ipairs(selected_values_table) do
        selected_values_set[value] = true
    end

    local current_selection_state = {}
    for _, option_info in ipairs(options_list) do
        current_selection_state[option_info.value] = selected_values_set[option_info.value] or false
    end

    local menu_items = {}
    local selection_menu

    for i, option_info in ipairs(options_list) do
        local option_value = option_info.value
        menu_items[i] = {
            text = option_info.name,
            mandatory_func = function()
                return current_selection_state[option_value] and "[X]" or "[ ]"
            end,
            callback = function()
                if is_single then
                    for value in pairs(current_selection_state) do
                        current_selection_state[value] = false
                    end
                    current_selection_state[option_value] = true
                else
                    current_selection_state[option_value] = not current_selection_state[option_value]
                end
                selection_menu:updateItems(nil, true)
                if is_single then
                    selection_menu:onClose()
                end
            end,
            keep_menu_open = true,
        }
    end

    selection_menu = Menu:new{
        title = title,
        item_table = menu_items,
        parent = parent_ui,
        show_captions = true,
        onClose = function()
            local ok, err = pcall(function()
                local new_selected_values = {}
                for value, is_selected in pairs(current_selection_state) do
                    if is_selected then table.insert(new_selected_values, value) end
                end

                table.sort(new_selected_values, function(a, b)
                    local name_a, name_b
                    for _, info in ipairs(options_list) do
                        if info.value == a then name_a = info.name end
                        if info.value == b then name_b = info.name end
                    end
                    return (name_a or "") < (name_b or "")
                end)

                if #new_selected_values > 0 then
                    Config.saveSetting(setting_key, new_selected_values)
                    return #new_selected_values
                else
                    Config.deleteSetting(setting_key)
                end
            end)

            UIManager:close(selection_menu)
            if ok then
                if type(ok_callback) == "function" then
                    ok_callback(err)
                else
                    Ui.showInfoMessage(string.format(T("%d items selected for %s."), err, title))
                end
            else
                logger.err("Annas:Ui._editConfigOptionsDialog - Error during onClose for %s: %s", title, tostring(err))
                Ui.showInfoMessage(string.format(T("Filter cleared for %s."), title))
            end
        end,
    }
    _showAndTrackDialog(selection_menu)
end

local function  _showRadioSelectionDialog(parent_ui, title, setting_key, options_list, ok_callback)
    _showMultiSelectionDialog(parent_ui, title, setting_key, options_list, ok_callback, true)
end

function Ui.showLanguageSelectionDialog(parent_ui, ok_callback)
    _showMultiSelectionDialog(parent_ui, T("Select search languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES, ok_callback)
end

function Ui.showExtensionSelectionDialog(parent_ui, ok_callback)
    _showMultiSelectionDialog(parent_ui, T("Select search formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS, ok_callback)
end

function Ui.showOrdersSelectionDialog(parent_ui, ok_callback)
    _showRadioSelectionDialog(parent_ui, T("Select search order"), Config.SETTINGS_SEARCH_ORDERS_KEY, Config.SUPPORTED_ORDERS, ok_callback)
end

function Ui.showGenericInputDialog(title, setting_key, current_value_or_default, is_password, validate_and_save_callback)
    local dialog

    dialog = InputDialog:new{
        title = title,
        input = current_value_or_default or "",
        text_type = is_password and "password" or nil,
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() _closeAndUntrackDialog(dialog) end,
            },
            {
                text = T("Set"),
                callback = function()
                    local raw_input = dialog:getInputText() or ""
                    local close_dialog_after_action = false

                    if validate_and_save_callback then
                        if validate_and_save_callback(raw_input, setting_key) then
                            Ui.showInfoMessage(T("Setting saved successfully!"))
                            close_dialog_after_action = true
                        end
                    else
                        local trimmed_input = util.trim(raw_input)
                        if trimmed_input ~= "" then
                            Config.saveSetting(setting_key, trimmed_input)
                            Ui.showInfoMessage(T("Setting saved successfully!"))
                        else
                            Config.deleteSetting(setting_key)
                            Ui.showInfoMessage(T("Setting cleared."))
                        end
                        close_dialog_after_action = true
                    end

                    if close_dialog_after_action then
                        _closeAndUntrackDialog(dialog)
                    end
                end,
            },
        }},
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
end

function Ui.showSearchDialog(parent_zlibrary, def_input)
    -- save last search input
    if Ui._last_search_input and not def_input then
        def_input = Ui._last_search_input
    end

    local dialog
    local search_order_name = Config.getSearchOrderName()
    
    local selected_languages = Config.getSearchLanguages()
    local selected_extensions = Config.getSearchExtensions()
    
    local lang_text = T("Set languages")
    if #selected_languages > 0 then
        if #selected_languages == 1 then
            lang_text = string.format(T("Language: %s"), selected_languages[1])
        else
            lang_text = string.format(T("Languages (%d)"), #selected_languages)
        end
    end
    
    local format_text = T("Set formats")
    if #selected_extensions > 0 then
        if #selected_extensions == 1 then
            for _, ext_info in ipairs(Config.SUPPORTED_EXTENSIONS) do
                if ext_info.value == selected_extensions[1] then
                    format_text = string.format(T("Format: %s"), ext_info.name)
                    break
                end
            end
        else
            format_text = string.format(T("Formats (%d)"), #selected_extensions)
        end
    end

    dialog = InputDialog:new{
        title = T("Anna's Archive search"),
        input = def_input,
        buttons = {{{
        text = T("Search"),
        callback = function()
            local query = dialog:getInputText()
            _closeAndUntrackDialog(dialog)

            if not query or not query:match("%S") then
                Ui.showErrorMessage(T("Please enter a search term."))
                return
            end
            Ui._last_search_input = query

            local trimmed_query = util.trim(query)
            parent_zlibrary:performSearch(trimmed_query)
        end,
        }},{{
            text = string.format("%s: %s \u{25BC}", T("Sort by"), search_order_name),
            callback = function()
                _closeAndUntrackDialog(dialog)
                Ui.showOrdersSelectionDialog(parent_zlibrary, function(count)
                    Ui.showSearchDialog(parent_zlibrary, def_input)
                end)
            end
        }},{{
            text = lang_text,
            callback = function()
                _closeAndUntrackDialog(dialog)
                _showMultiSelectionDialog(parent_zlibrary, T("Select search languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES, function(count)
                    Ui.showSearchDialog(parent_zlibrary, def_input)
                end)
            end
        },{
            text = format_text,
            callback = function()
                _closeAndUntrackDialog(dialog)
                _showMultiSelectionDialog(parent_zlibrary, T("Select search formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS, function(count)
                    Ui.showSearchDialog(parent_zlibrary, def_input)
                end)
            end
        }},{{
            text = T("Settings"),
            keep_menu_open = true,
            callback = function()
                _closeAndUntrackDialog(dialog)
                Ui.showSettingsDialog()
            end,
        }},{{
            text = T("Cancel"),
            id = "close",
            callback = function() _closeAndUntrackDialog(dialog) end,
        }}}
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
end

function Ui.createBookMenuItem(book_data, parent_zlibrary_instance)
    local year_str = (book_data.year and book_data.year ~= "N/A" and tostring(book_data.year) ~= "0") and (" (" .. book_data.year .. ")") or ""
    local title_for_html = (type(book_data.title) == "string" and book_data.title) or T("Unknown Title")
    local title = util.htmlEntitiesToUtf8(title_for_html)
    local author_for_html = (type(book_data.author) == "string" and book_data.author) or T("Unknown Author")
    local author = util.htmlEntitiesToUtf8(author_for_html)
    local combined_text = string.format("%s by %s%s", title, author, year_str)

    local additional_info_parts = {}
    local selected_extensions = Config.getSearchExtensions()
    local provider_label = _deriveProviderLabel(book_data)

    if provider_label and provider_label ~= T("Unavailable") then
        table.insert(additional_info_parts, _colon_concat(T("Source"), provider_label))
    end

    if book_data.format and book_data.format ~= "N/A" then
        if #selected_extensions ~= 1 then
            table.insert(additional_info_parts, book_data.format)
        end
    end
    if book_data.size and book_data.size ~= "N/A" then table.insert(additional_info_parts, book_data.size) end
    if book_data.rating and book_data.rating ~= "N/A" then table.insert(additional_info_parts, _colon_concat(T("Rating"), book_data.rating)) end

    if #additional_info_parts > 0 then
        combined_text = combined_text .. " | " .. table.concat(additional_info_parts, " | ")
    end

    return {
        text = combined_text,
        callback = function()
            Ui.showBookDetails(parent_zlibrary_instance, book_data)
        end,
        keep_menu_open = true,
        original_book_data_ref = book_data,
    }
end

function Ui.createSearchResultsMenu(parent_ui_ref, query_string, initial_menu_items)
    local search_order_name = Config.getSearchOrderName()
    local menu = Menu:new{
        title = _colon_concat(T("Search Results"), query_string),
        subtitle = string.format("%s: %s", T("Sort by"), search_order_name),
        item_table = initial_menu_items,
        parent = parent_ui_ref,
        items_per_page = 10,
        show_captions = true,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_show_more_text = true
    }
    _showAndTrackDialog(menu)
    return menu
end

function Ui.appendSearchResultsToMenu(menu_instance, new_menu_items)
    if not menu_instance or not menu_instance.item_table then return end
    for _, item_data in ipairs(new_menu_items) do
        table.insert(menu_instance.item_table, item_data)
    end
    menu_instance:switchItemTable(menu_instance.title, menu_instance.item_table, -1, nil, menu_instance.subtitle)
end

function Ui.showBookDetails(parent_zlibrary, book, clear_cache_callback)
    local details_menu_items = {}
    local details_menu

    local is_cache = (type(clear_cache_callback) == "function")
    local title_text_for_html = (type(book.title) == "string" and book.title) or ""
    local full_title = util.htmlEntitiesToUtf8(title_text_for_html)
    table.insert(details_menu_items, {
        text = _colon_concat(T("Title"), full_title),
        mandatory = "\u{25B7}",
        callback = function()
            if book.description and book.description ~= "" then
                local desc_for_html = (type(book.description) == "string" and book.description) or ""
                local full_description = util.htmlEntitiesToUtf8(util.trim(desc_for_html))
                full_description = string.gsub(full_description, "<[Bb][Rr]%s*/?>", "\n")
                full_description = string.gsub(full_description, "</[Pp]>", "\n\n")
                full_description = string.gsub(full_description, "<[^>]+>", "")
                full_description = string.gsub(full_description, "(\n\r?%s*){2,}", "\n\n")
                Ui.showFullTextDialog(T("Description"), full_description)
            else
                Ui.showSimpleMessageDialog(T("Full Title"), full_title)
            end
        end,
    })

    local author_text_for_html = (type(book.author) == "string" and book.author) or ""
    local full_author = util.htmlEntitiesToUtf8(author_text_for_html)
    table.insert(details_menu_items, {
        text = string.format("%s: %s", T("Author"), full_author),
        mandatory = "\u{25B7}",
        callback = function()
            Ui.showSearchDialog(parent_zlibrary, full_author)
        end,
    })

    if book.cover and book.cover ~= "" and book.hash then
        table.insert(details_menu_items, {
            text = string.format("%s %s", T("Cover"), T("(tap to view)")),
            mandatory = "\u{25B7}",
            callback = function()
                parent_zlibrary:downloadAndShowCover(book)
            end})
    end

    if book.year and book.year ~= "N/A" and tostring(book.year) ~= "0" then table.insert(details_menu_items, { text = _colon_concat(T("Year"), book.year), enabled = false }) end
    if book.lang and book.lang ~= "N/A" then table.insert(details_menu_items, { text = _colon_concat(T("Language"), book.lang), enabled = false }) end

    local provider_label = _deriveProviderLabel(book)
    if provider_label then
        table.insert(details_menu_items, { text = _colon_concat(T("Source"), provider_label), enabled = false })
    end

    local has_supported_provider = _hasSupportedProvider(book)

    if book.format and book.format ~= "N/A" then
        if book.download and has_supported_provider then
            table.insert(details_menu_items, {
                text = string.format(T("Format: %s (tap to download)"), book.format),
                mandatory = "\u{25B7}",
                callback = function()
                    parent_zlibrary:downloadBook(book)
                end,
            })
        else
            table.insert(details_menu_items, { text = string.format(T("Format: %s (No supported provider route)"), book.format), enabled = false })
        end
    elseif book.download and has_supported_provider then
        table.insert(details_menu_items, {
            text = T("Download Book (Unknown Format)"),
            mandatory = "\u{25B7}",
            callback = function()
                parent_zlibrary:downloadBook(book)
            end,
        })
    elseif book.download then
        table.insert(details_menu_items, {
            text = T("Download unavailable for this provider"),
            enabled = false,
        })
    end

    if book.size and book.size ~= "N/A" then table.insert(details_menu_items, { text = _colon_concat(T("Size"), book.size), enabled = false }) end
    if book.rating and book.rating ~= "N/A" then table.insert(details_menu_items, { text = _colon_concat(T("Rating"), book.rating), enabled = false }) end
    if book.publisher and book.publisher ~= "" then
        local publisher_for_html = (type(book.publisher) == "string" and book.publisher) or ""
        table.insert(details_menu_items, { text = _colon_concat(T("Publisher"), util.htmlEntitiesToUtf8(publisher_for_html)), enabled = false })
    end
    if book.series and book.series ~= "" then
        local series_for_html = (type(book.series) == "string" and book.series) or ""
        table.insert(details_menu_items, { text = _colon_concat(T("Series"), util.htmlEntitiesToUtf8(series_for_html)), enabled = false })
    end
    if book.pages and book.pages ~= 0 then table.insert(details_menu_items, { text = _colon_concat(T("Pages"), book.pages), enabled = false }) end

    table.insert(details_menu_items, { text = "---" })

    table.insert(details_menu_items, {
        text = T("Back"),
        mandatory = "\u{21A9}",
        callback = function()
            if details_menu then UIManager:close(details_menu) end
        end,
    })

    details_menu = Menu:new{
        title = T("Book Details"),
        subtitle = is_cache and "\u{F1C0}",
        title_bar_left_icon = is_cache and "cre.render.reload",
        item_table = details_menu_items,
        parent = parent_zlibrary.ui,
        show_captions = true,
        multilines_show_more_text = true
    }
    function details_menu:onLeftButtonTap()
        if is_cache then
            UIManager:close(self)
            clear_cache_callback()
        end
    end

    _showAndTrackDialog(details_menu)
end

function Ui.confirmDownload(filename, ok_callback)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            text = string.format(T("Download \"%s\"?"), filename),
            ok_text = T("Download"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    else
        local dialog = ConfirmBox:new{
            text = string.format(T("Download \"%s\"?"), filename),
            ok_text = T("Download"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        }
        UIManager:show(dialog)
    end
end

function Ui.confirmOpenBook(filename, has_wifi_toggle, default_turn_off_wifi, ok_open_callback, cancel_callback)
    local turn_off_wifi = default_turn_off_wifi

    local function showDialog()
        local full_text = string.format(T("\"%s\" downloaded successfully. Open it now?"), filename)

        local dialog
        local other_buttons = nil

        if has_wifi_toggle then
            other_buttons = {{
                {
                    text = turn_off_wifi and ("☑ " .. T("Turn off Wi-Fi after closing this dialog")) or ("☐ " .. T("Turn off Wi-Fi after closing this dialog")),
                    callback = function()
                        turn_off_wifi = not turn_off_wifi
                        Config.setTurnOffWifiAfterDownload(turn_off_wifi)
                        UIManager:close(dialog)
                        showDialog()
                    end,
                },
            }}
        end

        dialog = ConfirmBox:new{
            text = full_text,
            ok_text = T("Open book"),
            ok_callback = function()
                ok_open_callback(turn_off_wifi)
            end,
            cancel_text = T("Close"),
            cancel_callback = function()
                cancel_callback(turn_off_wifi)
            end,
            other_buttons = other_buttons,
            other_buttons_first = true,
        }

        _showAndTrackDialog(dialog)
    end

    showDialog()
end

function Ui.createSingleBookMenu(ui_self, title, menu_items)
    local menu = Menu:new{
        title = title or T("Book Details"),
        show_parent_menu = true,
        parent_menu_text = T("Back"),
        item_table = menu_items,
        parent = ui_self.view,
        items_per_page = 10,
        show_captions = true,
    }
    _showAndTrackDialog(menu)
    return menu
end

function Ui.showRetryErrorDialog(err_msg, operation_name, retry_callback, cancel_callback, loading_msg_to_close)
    local error_string = tostring(err_msg)
    

    local is_http_400 = string.match(error_string, "HTTP Error: 400")
    local is_timeout = string.find(error_string, T("Request timed out")) or 
                      string.find(error_string, "timeout") or 
                      string.find(error_string, "timed out") or
                      string.find(error_string, "sink timeout")
    local is_network_error = string.find(error_string, T("Network connection error")) or
                            string.find(error_string, T("Network request failed"))
    
    if is_http_400 or is_timeout or is_network_error then
        local retry_message
        if is_timeout then
            local timeout_info = ""
            local operation_lower = string.lower(tostring(operation_name))
            if string.find(operation_lower, "search") then
                local search_timeout = Config.getSearchTimeout()
                timeout_info = string.format(" (%ds)", search_timeout[1])
            elseif string.find(operation_lower, "cover") then
                local cover_timeout = Config.getCoverTimeout()
                timeout_info = string.format(" (%ds)", cover_timeout[1])
            elseif string.find(operation_lower, "download") then
                local download_timeout = Config.getDownloadTimeout()
                timeout_info = string.format(" (%ds)", download_timeout[1])
            end
            retry_message = string.format(T("%s failed due to a timeout%s. Would you like to retry?"), operation_name, timeout_info)
        elseif is_network_error then
            retry_message = string.format(T("%s failed due to a network error. Would you like to retry?"), operation_name)
        else
            retry_message = string.format(T("%s failed due to a temporary issue. Would you like to retry?"), operation_name)
        end
        
        if _plugin_instance and _plugin_instance.dialog_manager then
            _plugin_instance.dialog_manager:showConfirmDialog({
                text = retry_message,
                ok_text = T("Retry"),
                cancel_text = T("Cancel"),
                ok_callback = function()
                    if loading_msg_to_close then
                        Ui.closeMessage(loading_msg_to_close)
                    end
                    retry_callback()
                end,
                cancel_callback = function()
                    if loading_msg_to_close then
                        Ui.closeMessage(loading_msg_to_close)
                    end
                    cancel_callback(err_msg)
                end
            })
        else
            if loading_msg_to_close then
                Ui.closeMessage(loading_msg_to_close)
            end
            Ui.showErrorMessage(error_string)
            cancel_callback(err_msg)
        end
    else
        if loading_msg_to_close then
            Ui.closeMessage(loading_msg_to_close)
        end
        Ui.showErrorMessage(error_string)
        cancel_callback(err_msg)
    end
end

function Ui.showTimeoutConfigDialog(parent_ui, timeout_name, timeout_key, getter_func, setter_func, refresh_parent_callback)
    local current_timeout = getter_func()
    local block_timeout = current_timeout[1]
    local total_timeout = current_timeout[2]
    
    local dialog_items = {}
    local dialog_menu
    
    local function refreshDialog()
        local updated_timeout = getter_func()
        block_timeout = updated_timeout[1]
        total_timeout = updated_timeout[2]
        
        dialog_items[1].text = string.format(T("Block timeout: %s seconds"), tostring(block_timeout))
        dialog_items[2].text = string.format(T("Total timeout: %s"), total_timeout == -1 and T("infinite") or (tostring(total_timeout) .. " " .. T("seconds")))
        
        if dialog_menu then
            dialog_menu.subtitle = Config.formatTimeoutForDisplay(updated_timeout)
            dialog_menu:switchItemTable(dialog_menu.title, dialog_items, -1, nil, dialog_menu.subtitle)
        end
    end
    
    table.insert(dialog_items, {
        text = string.format(T("Block timeout: %s seconds"), tostring(block_timeout)),
        mandatory = "\u{25B7}",
        callback = function()
            Ui.showGenericInputDialog(
                string.format(T("Set %s block timeout (seconds)"), timeout_name),
                nil,
                tostring(block_timeout),
                false,
                function(input_text)
                    local new_block_timeout = tonumber(input_text)
                    if new_block_timeout and new_block_timeout >= 1 then
                        setter_func(new_block_timeout, total_timeout)
                        refreshDialog()
                        return true
                    else
                        Ui.showErrorMessage(T("Please enter a valid number (minimum 1 second)"))
                        return false
                    end
                end
            )
        end
    })
    
    table.insert(dialog_items, {
        text = string.format(T("Total timeout: %s"), total_timeout == -1 and T("infinite") or (tostring(total_timeout) .. " " .. T("seconds"))),
        mandatory = "\u{25B7}",
        callback = function()
            Ui.showGenericInputDialog(
                string.format(T("Set %s total timeout (seconds, -1 for infinite)"), timeout_name),
                nil,
                tostring(total_timeout),
                false,
                function(input_text)
                    local new_total_timeout = tonumber(input_text)
                    if new_total_timeout and (new_total_timeout >= 1 or new_total_timeout == -1) then
                        setter_func(block_timeout, new_total_timeout)
                        refreshDialog()
                        return true
                    else
                        Ui.showErrorMessage(T("Please enter a valid number (minimum 1 second or -1 for infinite)"))
                        return false
                    end
                end
            )
        end
    })
    
    table.insert(dialog_items, {
        text = "---"
    })
    
    table.insert(dialog_items, {
        text = T("Reset to defaults"),
        mandatory = "\u{1F5D8}",
        callback = function()
            if _plugin_instance and _plugin_instance.dialog_manager then
                _plugin_instance.dialog_manager:showConfirmDialog({
                    text = string.format(T("Reset %s timeouts to default values?"), timeout_name),
                    ok_text = T("Reset"),
                    cancel_text = T("Cancel"),
                    ok_callback = function()
                        Config.deleteSetting(timeout_key)
                        refreshDialog()
                        Ui.showInfoMessage(T("Timeout settings reset to defaults"))
                    end
                })
            end
        end
    })
    

    
    dialog_menu = Menu:new{
        title = string.format(T("%s Timeout Settings"), timeout_name),
        subtitle = Config.formatTimeoutForDisplay(current_timeout),
        item_table = dialog_items,
        parent = parent_ui,
        show_captions = true,
    }
    
    local original_onClose = dialog_menu.onClose
    dialog_menu.onClose = function(self)
        if original_onClose then
            original_onClose(self)
        end
        _closeAndUntrackDialog(self)
        if refresh_parent_callback then
            refresh_parent_callback()
        end
    end
    
    _showAndTrackDialog(dialog_menu)
end

function Ui.showAllTimeoutConfigDialog(parent_ui, on_close_callback)
    local timeout_items = {}
    local main_menu
    
    local function refreshMainDialog()
        if main_menu then
            main_menu:updateItems(nil, true)
        end
    end
    
    timeout_items = {
        {
            text = T("Search timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getSearchTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Search"), Config.SETTINGS_TIMEOUT_SEARCH_KEY,
                    Config.getSearchTimeout, Config.setSearchTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Download timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getDownloadTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Download"), Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY,
                    Config.getDownloadTimeout, Config.setDownloadTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Cover download timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getCoverTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Cover download"), Config.SETTINGS_TIMEOUT_COVER_KEY,
                    Config.getCoverTimeout, Config.setCoverTimeout, refreshMainDialog)
            end
        },
        {
            text = "---"
        },
        {
            text = T("Reset all timeouts to defaults"),
            callback = function()
                if _plugin_instance and _plugin_instance.dialog_manager then
                    _plugin_instance.dialog_manager:showConfirmDialog({
                        text = T("Reset all timeout settings to default values?"),
                        ok_text = T("Reset All"),
                        cancel_text = T("Cancel"),
                        ok_callback = function()
                            Config.deleteSetting(Config.SETTINGS_TIMEOUT_SEARCH_KEY)
                            Config.deleteSetting(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY)
                            Config.deleteSetting(Config.SETTINGS_TIMEOUT_COVER_KEY)
                            Ui.showInfoMessage(T("All timeout settings reset to defaults"))
                            refreshMainDialog()
                        end
                    })
                end
            end
        }
    }
    
    main_menu = Menu:new{
        title = T("Timeout Settings"),
        item_table = timeout_items,
        parent = parent_ui,
        show_captions = true,
    }

    local original_onClose = main_menu.onClose
    main_menu.onClose = function(self)
        if original_onClose then
            original_onClose(self)
        end
        if on_close_callback then
            on_close_callback()
        end
    end

    _showAndTrackDialog(main_menu)
end

return Ui
