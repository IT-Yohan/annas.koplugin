local logger = require("logger")
local ltn12 = require("ltn12")
local json = require("json")
local T = require("annas.gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local Api = require("annas.api")
local Config = require("annas.config")
--local Ui = require("annas.ui_ota")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Ota = {}

local current_ota_status_widget = nil
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function build_release_url(repo, channel)
    if channel == Config.OTA_CHANNEL_PRERELEASE then
        return "https://api.github.com/repos/" .. repo .. "/releases"
    end

    return "https://api.github.com/repos/" .. repo .. "/releases/latest"
end

local function build_github_headers(accept)
    local headers = {
        ["User-Agent"] = "KOReader-Annas-Plugin",
        ["Accept"] = accept or "application/vnd.github.v3+json",
    }

    local token = Config.getOtaToken()
    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    return headers
end

local function normalize_release_info(payload, channel)
    if channel ~= Config.OTA_CHANNEL_PRERELEASE then
        return payload
    end

    if type(payload) ~= "table" then
        return nil
    end

    for _, release_info in ipairs(payload) do
        if type(release_info) == "table" and not release_info.draft then
            return release_info
        end
    end

    return nil
end

local function normalize_path(path)
    local normalized = tostring(path or ""):gsub("\\", "/"):gsub("/+", "/")
    if #normalized > 1 then
        normalized = normalized:gsub("/$", "")
    end
    return normalized
end

local function join_path(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if part and part ~= "" then
            table.insert(parts, tostring(part))
        end
    end
    return normalize_path(table.concat(parts, "/"))
end

local function dirname(path)
    return normalize_path(util.splitFilePathName(normalize_path(path)))
end

local function basename(path)
    return normalize_path(path):match("([^/]+)$")
end

local function command_succeeded(ok, exit_type, exit_code)
    if ok == true then
        return true
    end

    if type(ok) == "number" then
        return ok == 0
    end

    if type(exit_code) == "number" then
        return exit_code == 0
    end

    return false
end

local function command_exists(cmd)
    local probes = {}
    if IS_WINDOWS then
        table.insert(probes, string.format('where /Q %s >NUL 2>NUL', cmd))
    else
        table.insert(probes, string.format('command -v %s >/dev/null 2>&1', cmd))
        table.insert(probes, string.format('which %s >/dev/null 2>&1', cmd))
    end

    for _, probe in ipairs(probes) do
        local ok, exit_type, exit_code = os.execute(probe)
        if command_succeeded(ok, exit_type, exit_code) then
            return true
        end
    end

    return false
end

local function ensure_directory(path)
    if util.directoryExists(path) then
        return true
    end

    util.makePath(path)
    return util.directoryExists(path)
end

local function copy_file(source_path, target_path)
    local source, source_err = io.open(source_path, "rb")
    if not source then
        return false, source_err
    end

    if not ensure_directory(dirname(target_path)) then
        source:close()
        return false, "could not create target directory"
    end

    local target, target_err = io.open(target_path, "wb")
    if not target then
        source:close()
        return false, target_err
    end

    while true do
        local chunk = source:read(65536)
        if not chunk then
            break
        end

        local ok, write_err = target:write(chunk)
        if not ok then
            source:close()
            target:close()
            return false, write_err
        end
    end

    source:close()
    target:close()
    return true
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then
        return true
    end

    if mode == "file" then
        local ok, err = os.remove(path)
        return ok ~= nil, err
    end

    if mode ~= "directory" then
        return false, "unsupported node type: " .. tostring(mode)
    end

    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local ok, err = remove_tree(join_path(path, entry))
            if not ok then
                return false, err
            end
        end
    end

    local ok, err = lfs.rmdir(path)
    return ok ~= nil, err
end

local function copy_tree(source_dir, target_dir)
    if not ensure_directory(target_dir) then
        return false, "could not create target directory"
    end

    for entry in lfs.dir(source_dir) do
        if entry ~= "." and entry ~= ".." then
            local source_path = join_path(source_dir, entry)
            local target_path = join_path(target_dir, entry)
            local mode = lfs.attributes(source_path, "mode")

            if mode == "directory" then
                local ok, err = copy_tree(source_path, target_path)
                if not ok then
                    return false, err
                end
            elseif mode == "file" then
                local ok, err = copy_file(source_path, target_path)
                if not ok then
                    return false, err
                end
            else
                return false, "unsupported node type: " .. tostring(mode)
            end
        end
    end

    return true
end

local function prepare_clean_directory(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        local ok, err = remove_tree(path)
        if not ok then
            return false, err
        end
    elseif mode == "file" then
        local ok, err = os.remove(path)
        if not ok then
            return false, err
        end
    end

    if not ensure_directory(path) then
        return false, "could not create directory"
    end

    return true
end

local function find_extracted_plugin_root(extract_dir, plugin_name)
    if util.fileExists(join_path(extract_dir, "_meta.lua")) then
        return extract_dir
    end

    local fallback_dir = nil
    for entry in lfs.dir(extract_dir) do
        if entry ~= "." and entry ~= ".." then
            local path = join_path(extract_dir, entry)
            if lfs.attributes(path, "mode") == "directory" then
                if basename(path) == plugin_name and util.fileExists(join_path(path, "_meta.lua")) then
                    return path
                end

                if util.fileExists(join_path(path, "_meta.lua")) then
                    fallback_dir = path
                end
            end
        end
    end

    return fallback_dir
end

local function extract_zip_with_shell(zip_filepath, destination_dir)
    local extractors = {
        {
            available = function()
                return command_exists("unzip")
            end,
            build = function(zip_path, dest_path)
                return string.format('unzip -o "%s" -d "%s"', zip_path, dest_path)
            end,
        },
        {
            available = function()
                return command_exists("tar")
            end,
            build = function(zip_path, dest_path)
                return string.format('tar -xf "%s" -C "%s"', zip_path, dest_path)
            end,
        },
    }

    for _, extractor in ipairs(extractors) do
        if extractor.available() then
            local command = extractor.build(zip_filepath, destination_dir)
            logger.info("Annas:Ota.installUpdate - Extracting archive with: " .. command)
            local ok, exit_type, exit_code = os.execute(command)
            if command_succeeded(ok, exit_type, exit_code) then
                return true
            end

            return false, string.format("archive extraction failed (exit code: %s)", tostring(exit_code or ok))
        end
    end

    return false, "no supported archive extractor is available"
end

local function choose_release_package(release_info)
    local preferred_asset_name = Config.getOtaAssetName()

    if type(release_info.assets) == "table" then
        for _, asset in ipairs(release_info.assets) do
            if asset.name == preferred_asset_name and (asset.url or asset.browser_download_url) then
                return {
                    url = asset.url or asset.browser_download_url,
                    name = asset.name,
                    use_api_asset = asset.url ~= nil,
                }
            end
        end

        for _, asset in ipairs(release_info.assets) do
            if asset.name == "annas.koplugin.zip" and (asset.url or asset.browser_download_url) then
                return {
                    url = asset.url or asset.browser_download_url,
                    name = asset.name,
                    use_api_asset = asset.url ~= nil,
                }
            end
        end

        for _, asset in ipairs(release_info.assets) do
            if type(asset.name) == "string" and asset.name:match("%.zip$") and asset.browser_download_url then
                return {
                    url = asset.url or asset.browser_download_url,
                    name = asset.name,
                    use_api_asset = asset.url ~= nil,
                }
            end
        end
    end

    if Config.getOtaAllowZipball() and release_info.zipball_url then
        return {
            url = release_info.zipball_url,
            name = "annas_plugin_update.zip",
            use_api_asset = false,
        }
    end

    return nil
end

local function _close_current_ota_status_widget()
    if current_ota_status_widget then
        local Ui = require("annas.ui")
        Ui.closeMessage(current_ota_status_widget)
        current_ota_status_widget = nil
    end
end

local function _show_ota_status_loading(text)
    _close_current_ota_status_widget()
    local Ui = require("annas.ui")
    current_ota_status_widget = Ui.showLoadingMessage(text)
end

local function _show_ota_final_message(text, is_error)
    _close_current_ota_status_widget()
    local Ui = require("annas.ui")
    if is_error then
        Ui.showErrorMessage(text)
    else
        Ui.showInfoMessage(text)
    end
end

function Ota.getCurrentPluginVersion(plugin_base_path)
    local meta_file_full_path = plugin_base_path .. "/_meta.lua"
    logger.info("Annas:Ota.getCurrentPluginVersion - Attempting to load version via dofile from: " .. meta_file_full_path)

    local ok, result = pcall(dofile, meta_file_full_path)

    if not ok then
        logger.err("Annas:Ota.getCurrentPluginVersion - Error executing _meta.lua: " .. tostring(result))
        return nil
    end

    if type(result) == "table" and result.version and type(result.version) == "string" then
        logger.info("Annas:Ota.getCurrentPluginVersion - Found version: " .. result.version)
        return result.version
    else
        local details = "Unknown issue."
        if type(result) ~= "table" then
            details = "_meta.lua did not return a table. Returned type: " .. type(result) .. ", value: " .. tostring(result)
        elseif not result.version then
            details = "_meta.lua returned a table, but the 'version' key is missing."
        elseif type(result.version) ~= "string" then
            details = "_meta.lua returned a table, but 'version' is not a string. Type: " .. type(result.version)
        end
        logger.warn("Annas:Ota.getCurrentPluginVersion - Version not found or invalid in _meta.lua. " .. details)
        return nil
    end
end

local function isVersionOlder(version1, version2)
    if not version1 or not version2 then return false end

    local v1_parts = {}
    for part in string.gmatch(version1, "([^%.]+)") do table.insert(v1_parts, tonumber(part)) end
    local v2_parts = {}
    for part in string.gmatch(version2, "([^%.]+)") do table.insert(v2_parts, tonumber(part)) end

    for i = 1, math.max(#v1_parts, #v2_parts) do
        local p1 = v1_parts[i] or 0
        local p2 = v2_parts[i] or 0
        if p1 < p2 then return true end
        if p1 > p2 then return false end
    end
    return false
end

function Ota.fetchLatestReleaseInfo()
    local repo = Config.getOtaRepo()
    local channel = Config.getOtaChannel()
    local release_url = build_release_url(repo, channel)
    logger.info("Annas:Ota.fetchLatestReleaseInfo - START for repo: " .. repo .. ", channel: " .. channel)
    local result = { release_info = nil, error = nil }

    local http_options = {
        url = release_url,
        method = "GET",
        headers = build_github_headers("application/vnd.github.v3+json"),
        timeout = 20,
    }

    local http_result = Api.makeHttpRequest(http_options)

    if http_result.error then
        result.error = "Network request failed: " .. http_result.error
        logger.err("Annas:Ota.fetchLatestReleaseInfo - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("HTTP Error: %s. Body: %s", http_result.status_code, http_result.body or "N/A")
        logger.err("Annas:Ota.fetchLatestReleaseInfo - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    if not http_result.body then
        result.error = "No response body from GitHub API."
        logger.err("Annas:Ota.fetchLatestReleaseInfo - END (No body error) - Error: " .. result.error)
        return result
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        result.error = "Failed to decode JSON response: " .. tostring(data)
        logger.err("Annas:Ota.fetchLatestReleaseInfo - END (JSON error) - Error: " .. result.error)
        return result
    end

    local release_info = normalize_release_info(data, channel)
    if not release_info then
        result.error = "No matching release found for configured OTA channel"
        logger.err("Annas:Ota.fetchLatestReleaseInfo - END (No release) - Error: " .. result.error)
        return result
    end

    logger.info("Annas:Ota.fetchLatestReleaseInfo - END (Success)")
    result.release_info = release_info
    return result
end

function Ota.downloadUpdate(url, destination_path, headers)
    logger.info(string.format("Annas:Ota.downloadUpdate - START - URL: %s, Dest: %s", url, destination_path))
    local result = { success = false, error = nil }

    local file, err_open = io.open(destination_path, "wb")
    if not file then
        result.error = "Failed to open target file for download: " .. (err_open or "Unknown error")
        logger.err("Annas:Ota.downloadUpdate - END (File open error) - " .. result.error)
        return result
    end

    local sink = ltn12.sink.file(file)
    local http_options = {
        url = url,
        method = "GET",
        headers = headers or build_github_headers(),
        sink = sink,
        timeout = 300,
    }

    local http_result = Api.makeHttpRequest(http_options)

    if http_result.error then
        result.error = "Download network request failed: " .. http_result.error
        pcall(os.remove, destination_path)
        logger.err("Annas:Ota.downloadUpdate - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("Download HTTP Error: %s", http_result.status_code)
        pcall(os.remove, destination_path)
        logger.err("Annas:Ota.downloadUpdate - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    logger.info("Annas:Ota.downloadUpdate - END (Success)")
    result.success = true
    return result
end

function Ota.installUpdate(zip_filepath, plugin_base_path)
    logger.info("Annas:Ota.installUpdate - START - File: " .. zip_filepath .. " Target Path: " .. plugin_base_path)

    local target_plugin_path = normalize_path(plugin_base_path)
    local plugin_parent_dir = dirname(target_plugin_path)
    local plugin_name = basename(target_plugin_path)
    local ota_cache_dir = join_path(DataStorage:getDataDir(), "cache", "annas", "ota")
    local extract_dir = join_path(ota_cache_dir, "extract")
    local backup_dir = join_path(plugin_parent_dir, plugin_name .. ".ota-backup")

    if not plugin_base_path or not util.directoryExists(target_plugin_path) then
        local err_msg = "Invalid or missing plugin base path for installation: " .. tostring(plugin_base_path)
        logger.err("Annas:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update failed: Could not determine where to install the plugin."), true)
        return { error = err_msg }
    end

    if not plugin_parent_dir or plugin_parent_dir == "" or not util.directoryExists(plugin_parent_dir) then
        local err_msg = "Invalid plugin parent directory for installation: " .. tostring(plugin_parent_dir)
        logger.err("Annas:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update failed: Could not determine where to install the plugin."), true)
        return { error = err_msg }
    end

    _show_ota_status_loading(T("Installing update..."))

    if not ensure_directory(ota_cache_dir) then
        local err_msg = "Could not create OTA cache directory: " .. ota_cache_dir
        logger.err("Annas:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = err_msg }
    end

    local prep_ok, prep_err = prepare_clean_directory(extract_dir)
    if not prep_ok then
        local err_msg = "Could not prepare extraction directory: " .. tostring(prep_err)
        logger.err("Annas:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = err_msg }
    end

    local extract_ok, extract_err = extract_zip_with_shell(zip_filepath, extract_dir)
    if not extract_ok then
        logger.err("Annas:Ota.installUpdate - Failed to extract ZIP: " .. tostring(extract_err))
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = "Failed to extract update package: " .. tostring(extract_err) }
    end

    local unpacked_dir = find_extracted_plugin_root(extract_dir, plugin_name)
    if not unpacked_dir then
        logger.err("Annas:Ota.installUpdate - Could not locate extracted plugin files in " .. extract_dir)
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = "Could not locate extracted plugin files." }
    end

    if util.directoryExists(backup_dir) then
        local cleanup_backup_ok, cleanup_backup_err = remove_tree(backup_dir)
        if not cleanup_backup_ok then
            logger.err("Annas:Ota.installUpdate - Could not clean previous OTA backup: " .. tostring(cleanup_backup_err))
            _show_ota_final_message(T("Update installation failed."), true)
            return { error = "Could not clean previous OTA backup." }
        end
    end

    local moved_to_backup, move_backup_err = os.rename(target_plugin_path, backup_dir)
    if not moved_to_backup then
        logger.err("Annas:Ota.installUpdate - Could not stage existing plugin for rollback: " .. tostring(move_backup_err))
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = "Could not stage existing plugin for rollback." }
    end

    if not ensure_directory(target_plugin_path) then
        os.rename(backup_dir, target_plugin_path)
        logger.err("Annas:Ota.installUpdate - Could not create target plugin directory: " .. target_plugin_path)
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = "Could not create target plugin directory." }
    end

    local copy_ok, copy_err = copy_tree(unpacked_dir, target_plugin_path)
    if not copy_ok then
        logger.err("Annas:Ota.installUpdate - Failed to copy extracted plugin files: " .. tostring(copy_err))
        remove_tree(target_plugin_path)
        local rollback_ok, rollback_err = os.rename(backup_dir, target_plugin_path)
        if not rollback_ok then
            logger.err("Annas:Ota.installUpdate - Rollback failed: " .. tostring(rollback_err))
        end
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = "Failed to copy extracted plugin files: " .. tostring(copy_err) }
    end

    local cleanup_backup_ok, cleanup_backup_err = remove_tree(backup_dir)
    if not cleanup_backup_ok then
        logger.warn("Annas:Ota.installUpdate - Could not remove OTA backup directory: " .. tostring(cleanup_backup_err))
    end

    local rm_ok, rm_err = os.remove(zip_filepath)
    if not rm_ok then
        logger.warn("Annas:Ota.installUpdate - Could not remove downloaded ZIP file: " .. zip_filepath .. " Error: " .. tostring(rm_err))
    else
        logger.info("Annas:Ota.installUpdate - Cleaned up ZIP file: " .. zip_filepath)
    end

    local cleanup_extract_ok, cleanup_extract_err = remove_tree(extract_dir)
    if not cleanup_extract_ok then
        logger.warn("Annas:Ota.installUpdate - Could not remove extraction directory: " .. tostring(cleanup_extract_err))
    end

    _show_ota_final_message(T([[Update installed successfully. Please restart KOReader for changes to take effect.]]), false)
    return { success = true, message = "Update installed successfully." }
end

function Ota.startUpdateProcess(plugin_path_from_main)
    logger.info("Annas:Ota.startUpdateProcess - Initiated by user. Plugin path: " .. tostring(plugin_path_from_main))

    if not Config.getOtaEnabled() then
        logger.info("Annas:Ota.startUpdateProcess - OTA is disabled in settings.")
        _show_ota_final_message(T("OTA updates are disabled in Anna Settings."), false)
        return
    end

    if not NetworkMgr:isOnline() then
        logger.warn("Annas:Ota.startUpdateProcess - No internet connection.")
        _show_ota_final_message(T("No internet connection detected. Please connect to the internet and try again."), true)
        return
    end

    if not plugin_path_from_main then
        logger.err("Annas:Ota.startUpdateProcess - Plugin path not provided.")
        _show_ota_final_message(T("Update check failed: Could not determine plugin location."), true)
        return
    end

    local normalized_plugin_path = normalize_path(plugin_path_from_main)
    if basename(normalized_plugin_path) ~= "annas.koplugin" or not util.fileExists(join_path(normalized_plugin_path, "_meta.lua")) then
        local err_msg = string.format(T("Unsupported plugin path for OTA update: %s."), plugin_path_from_main)
        logger.err("Annas:Ota.startUpdateProcess - " .. err_msg)
        _show_ota_final_message(err_msg, true)
        return
    end

    _show_ota_status_loading(T("Checking for updates..."))

    local fetch_result = Ota.fetchLatestReleaseInfo()

    if fetch_result.error or not fetch_result.release_info then
        logger.err("Annas:Ota.startUpdateProcess - Failed to fetch release info: " .. (fetch_result.error or "Unknown error - release_info is nil"))
        _show_ota_final_message(T("Failed to check for updates. Please check your internet connection."), true)
        return
    end

    local release_info = fetch_result.release_info
    if not release_info or type(release_info) ~= "table" then
        logger.err("Annas:Ota.startUpdateProcess - Invalid release_info structure received.")
        _show_ota_final_message(T("Could not find update information (invalid data format)."), true)
        return
    end

    local latest_version_tag = release_info.tag_name

    if not latest_version_tag or type(latest_version_tag) ~= "string" or #latest_version_tag == 0 then
        logger.warn("Annas:Ota.startUpdateProcess - Invalid or missing latest_version_tag in release information.")
        _show_ota_final_message(T("Could not find update version information."), true)
        return
    end

    local normalized_latest_version = string.match(latest_version_tag, "v?([%d%.]+)")
    if not normalized_latest_version then
        logger.warn("Annas:Ota.startUpdateProcess - Could not normalize latest_version_tag: " .. latest_version_tag)
        _show_ota_final_message(T("Could not understand the update version format."), true)
        return
    end
    logger.info("Annas:Ota.startUpdateProcess - GitHub tag: " .. latest_version_tag .. ", Normalized latest version: " .. normalized_latest_version)

    local package_info = choose_release_package(release_info)
    if not package_info or not package_info.url then
        logger.warn("Annas:Ota.startUpdateProcess - No download URL found in release information.")
        _show_ota_final_message(T("Could not find a download link for the configured update source."), true)
        return
    end

    local download_url = package_info.url
    local release_msg = type(release_info.body) == "string" and release_info.body:match("([^%.]*)") or ""
    local asset_name = package_info.name or "annas_plugin_update.zip"

    local current_version = Ota.getCurrentPluginVersion(plugin_path_from_main)
    if not current_version then
        logger.warn("Annas:Ota.startUpdateProcess - Could not determine current plugin version. Proceeding with update check, but comparison might be skipped.")
    end

    logger.info(string.format("Annas:Ota.startUpdateProcess - Latest version from GitHub (normalized): %s, Current installed version: %s", normalized_latest_version, current_version or "Unknown"))

    if current_version and not isVersionOlder(current_version, normalized_latest_version) then
        local message
        if current_version then
            message = string.format(T("You are already on the latest version (%s) or newer."), current_version)
        else
            message = string.format(T("Could not determine your current version, but the latest is %s. If you recently updated, you might be up-to-date."), normalized_latest_version)
        end
        _show_ota_final_message(message, false)
        logger.info("Annas:Ota.startUpdateProcess - No new update needed. Current: " .. (current_version or "Unknown") .. ", Latest (normalized): " .. normalized_latest_version)
        return
    end

    local confirmation_message = string.format(T("New version available: %s (you have %s). %s. Download and install?"),
        normalized_latest_version,
        current_version or T("an older version"),
        release_msg
    )

    local confirm_dialog = ConfirmBox:new{
        title = T("Update available"),
        text = confirmation_message,
        ok_text = T("Update"),
        cancel_text = T("Cancel"),
        ok_callback = function()
            _show_ota_status_loading(T("Downloading update..."))
            local temp_path_base = DataStorage:getDataDir() .. "/cache"
            local temp_zip_path = temp_path_base .. "/" .. asset_name

            ensure_directory(temp_path_base)

            logger.info("Annas:Ota.startUpdateProcess - Temporary download path: " .. temp_zip_path)

            local download_headers = package_info.use_api_asset
                and build_github_headers("application/octet-stream")
                or build_github_headers()

            local download_result = Ota.downloadUpdate(download_url, temp_zip_path, download_headers)

            if download_result.error or not download_result.success then
                logger.err("Annas:Ota.startUpdateProcess - Download failed: " .. (download_result.error or "Unknown error"))
                _show_ota_final_message(T("Download failed. Check OTA repository settings, token access, and internet connectivity."), true)
                if util.fileExists(temp_zip_path) then
                    os.remove(temp_zip_path)
                end
                return
            end

            logger.info("Annas:Ota.startUpdateProcess - Download successful: " .. temp_zip_path)
            local install_result = Ota.installUpdate(temp_zip_path, plugin_path_from_main)

            if install_result.error then
                logger.err("Annas:Ota.startUpdateProcess - Installation failed: " .. install_result.error)
            else
                logger.info("Annas:Ota.startUpdateProcess - Installation successful.")
            end

            if util.fileExists(temp_zip_path) and (install_result.error or not install_result.success) then
                local rm_ok, rm_err = os.remove(temp_zip_path)
                if not rm_ok then
                    logger.warn("Annas:Ota.startUpdateProcess - Could not remove temp ZIP after failed/partial install: " .. temp_zip_path .. " Error: " .. tostring(rm_err))
                end
            end
        end,
        cancel_callback = function()
            _close_current_ota_status_widget()
            logger.info("Annas:Ota.startUpdateProcess - User cancelled update.")
        end
    }
    UIManager:setDirty("all", "full")
    UIManager:show(confirm_dialog)
    UIManager:setDirty("all", "full")
end

return Ota
