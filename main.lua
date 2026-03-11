--[[--
@module koplugin.Annas
--]]--

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("annas.gettext")
local Config = require("annas.config")
local Api = require("annas.api")
local Ui = require("annas.ui")
local ReaderUI = require("apps/reader/readerui")
local AsyncHelper = require("annas.async_helper")
local logger = require("logger")
local Ota = require("annas.ota")
local Cache = require("annas.cache")
local Device = require("device")
local DialogManager = require("annas.dialog_manager")

require('src.scraper')

local Annas = WidgetContainer:extend{
    name = T("Anna's Archive"),
    is_doc_only = false,
    plugin_path = nil,
    dialog_manager = nil,
}

function Annas:onDispatcherRegisterActions()
    Dispatcher:registerAction("annas_search", { category="none", event="AnnasSearch", title=T("Anna's Archive search"), general=true,})
end

function Annas:init()
    local full_source_path = debug.getinfo(1, "S").source
    if full_source_path:sub(1,1) == "@" then
        full_source_path = full_source_path:sub(2)
    end
    self.plugin_path, _ = util.splitFilePathName(full_source_path):gsub("/+", "/")

    Config.migrateLegacySettings()
    Config.cleanupObsoleteSettings()
    
    local current_version = Ota.getCurrentPluginVersion(self.plugin_path)
    
    self.dialog_manager = DialogManager:new()
    Ui.setPluginInstance(self)
    
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("self.ui or self.ui.menu not initialized in Annas:init")
    end

    logger.info(string.format("Annas: Init successful, version is: %s", current_version))

end

function Annas:onAnnasSearch()
    local def_search_input
    if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
      local doc_props = self.ui.doc_settings.data.doc_props
      def_search_input = doc_props.authors or doc_props.title
    end
    Ui.showSearchDialog(self, def_search_input)
    return true
end

function Annas:addToMainMenu(menu_items)

    if not self.ui.view then
        menu_items.annas_main = {
            sorting_hint = "search",
            text = T("Anna's Archive"),
            callback = function()
                Ui.showSearchDialog(self)
            end,
        }
    end
end

function Annas:performSearch(query)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    local function runSearch(loading_text)
        local loading_msg = Ui.showLoadingMessage(loading_text)

        local function task_search()
            local results, err = scraper(query)
            if not results then
                error(err or T("Search failed. Please try again later."))
            end
            return results
        end

        local function on_success_search(results)
            if #results == 0 then
                Ui.showInfoMessage(T("No results found for \"") .. query .. "\".")
                return
            end

            logger.info(string.format("Annas:performSearch - Fetch successful. Results: %d", #results))
            self.current_search_query = query
            self.all_search_results_data = results

            UIManager:nextTick(function()
                self:displaySearchResults(self.all_search_results_data, self.current_search_query)
            end)
        end

        local function on_error_search(err_msg)
            logger.warn(string.format("Annas:performSearch - Search failed: %s", tostring(err_msg)))
            Ui.showRetryErrorDialog(err_msg, T("Search"), function()
                runSearch(T("Retrying search..."))
            end, function()
            end, loading_msg)
        end

        AsyncHelper.run(task_search, on_success_search, on_error_search, loading_msg)
    end

    runSearch(T("Searching for \"") .. query .. "\"...")
end

function Annas:displaySearchResults(initial_book_data_list, query_string)
    if not initial_book_data_list or #initial_book_data_list == 0 then
        logger.info("Annas:displaySearchResults - No initial results to display.")
        return
    end

    local menu_items = {}
    logger.info(string.format("Annas:displaySearchResults - Preparing menu items from %d initial results.", #initial_book_data_list))

    for i = 1, #initial_book_data_list do
        local book_menu_item_data = initial_book_data_list[i]
        menu_items[i] = Ui.createBookMenuItem(book_menu_item_data, self)
    end

    if self.active_results_menu then
        UIManager:close(self.active_results_menu)
        self.active_results_menu = nil
    end

    self.active_results_menu = Ui.createSearchResultsMenu(self.ui, query_string, menu_items)
end

function Annas:downloadBook(book)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    if not book.download then
        Ui.showErrorMessage(T("No download link available for this book."))
        return
    end

    --[[     local download_url = Config.getDownloadUrl(book.download)
    logger.info(string.format("Annas:downloadBook - Download URL: %s", download_url))

    local safe_title = util.trim(book.title or "Unknown Title"):gsub("[/\\?%*:|\"<>%c]", "_")
    local safe_author = util.trim(book.author or "Unknown Author"):gsub("[/\\?%*:|\"<>%c]", "_")
    local filename = string.format("%s - %s.%s", safe_title, safe_author, book.format or "unknown")
    logger.info(string.format("Annas:downloadBook - Proposed filename: %s", filename)) ]]

    local target_dir = Config.getDownloadDir()

    if not target_dir then
        target_dir = Config.DEFAULT_DOWNLOAD_DIR_FALLBACK
        logger.warn(string.format("Annas:downloadBook - Download directory setting not found, using fallback: %s", target_dir))
    else
        logger.info(string.format("Annas:downloadBook - Using configured download directory: %s", target_dir))
    end

    if lfs.attributes(target_dir, "mode") ~= "directory" then
        local ok, err_mkdir = lfs.mkdir(target_dir)
        if not ok then
            Ui.showErrorMessage(string.format(T("Cannot create downloads directory: %s"), err_mkdir or "Unknown error"))
            return
        end
        logger.info(string.format("Annas:downloadBook - Created downloads directory: %s", target_dir))
    end

    --local target_filepath = target_dir .. "/" .. filename
    --logger.info(string.format("Annas:downloadBook - Target filepath: %s", target_filepath))

    local function attemptDownload()
        local loading_msg = Ui.showLoadingMessage(T("Downloading, please wait …"))

        local function task_download()
            local downloaded_file, err = download_book(book, target_dir)
            if not downloaded_file then
                error(err or T("Download failed. Please try again later."))
            end
            return downloaded_file
        end

        local function on_success_download(downloaded_file)
            local has_wifi_toggle = Device:hasWifiToggle()
            local default_turn_off_wifi = Config.getTurnOffWifiAfterDownload()

            Ui.confirmOpenBook(downloaded_file, has_wifi_toggle, default_turn_off_wifi, function(should_turn_off_wifi)
                if should_turn_off_wifi then
                    NetworkMgr:disableWifi(function()
                        logger.info("Annas:downloadBook - Wi-Fi disabled after download as requested by user")
                    end)
                end

                if ReaderUI then
                    logger.info("Annas:downloadBook - Cleaning up dialogs before opening reader")
                    self.dialog_manager:closeAllDialogs()
                    ReaderUI:showReader(downloaded_file)
                else
                    Ui.showErrorMessage(T("Could not open reader UI."))
                    logger.warn("Annas:downloadBook - ReaderUI not available.")
                end
            end,
            function(should_turn_off_wifi)
                if should_turn_off_wifi then
                    NetworkMgr:disableWifi(function()
                        logger.info("Annas:downloadBook - Wi-Fi disabled after download as requested by user")
                    end)
                    logger.info("Annas:downloadBook - Cleaning up dialogs cause wifi is turned off")
                    self.dialog_manager:closeAllDialogs()
                end
            end)
        end

        local function on_error_download(err_msg)
            local error_string = tostring(err_msg)
            if string.find(error_string, "Download limit reached or file is an HTML page", 1, true) then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download limit reached. Please try again later or check your account."))
                return
            end
            
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Download"), function()
                -- Retry callback
                local new_loading_msg = Ui.showLoadingMessage(T("Retrying download..."))
                loading_msg = new_loading_msg
                AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end, loading_msg)
        end

        AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
    end

    Ui.confirmDownload(book.title, function()
        attemptDownload()
    end)
end

function Annas:downloadAndShowCover(book)
    local cover_url = book.cover
    local book_id = book.id
    local book_hash = book.hash
    local book_title = book.title

    if not (cover_url and book_id and book_hash) then
        logger.warn("Annas:downloadAndShowCover - parameter error")
        return
    end

    local function getImgExtension(url)
       local clean_url = url:match("^([^%?]+)") or url
       return clean_url:match("[%.]([^%.]+)$") or "jpg"
    end

    local cover_ext = getImgExtension(cover_url)
    local cache_path = Cache:makePath(book_id, book_hash)
    local cover_cache_path = string.format("%s.%s", cache_path, cover_ext)
    cover_cache_path = Cache:resolveExistingPath(cover_cache_path)

    if not util.fileExists(cover_cache_path) then
        local download_result = Api.downloadBookCover(cover_url, cover_cache_path)
        if download_result.error or not download_result.success then
            if util.fileExists(cover_cache_path) then
                    pcall(os.remove, cover_cache_path)
            end
            Ui.showErrorMessage(tostring(download_result.error))
            return
        end
    end

    Ui.showCoverDialog(book_title, cover_cache_path)
end

function Annas:onExit()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("Annas:onExit - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
end

function Annas:onCloseWidget()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("Annas:onCloseWidget - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
end

return Annas