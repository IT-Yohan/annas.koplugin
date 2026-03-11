local Config = require("annas.config")
local Api = require("annas.api")
local T = require("annas.gettext")
local logger = require("logger")
local util = require("util")
local DataStorage = require("datastorage")

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/annas"
local CACHE_FILE = CACHE_DIR .. "/domains.txt"
local LEGACY_CACHE_FILE = "annas_domains_cache.txt"
local CACHE_DURATION = 12 * 60 * 60
local FALLBACK_DOMAINS = {
    "annas-archive.li",
    "annas-archive.gl",
    "annas-archive.org",
    "annas-archive.se",
    "annas-archive.gs",
    "annas-archive.pm",
    "annas-archive.in",
}
local SEARCH_RESULT_SPLIT_PATTERN = "pt-3 pb-3 border-b last:border-b-0 border-gray-100"
local ANTI_BOT_MARKERS = {
    "ddos-guard",
    "captcha",
    "access denied",
    "cf-browser-verification",
    "just a moment",
    "checking if the site connection is secure",
    "/cdn-cgi/challenge-platform",
    "please enable javascript",
}
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local COMMAND_EXISTS_CACHE = {}

local function ensure_cache_dir()
    if util.directoryExists(CACHE_DIR) then
        return true
    end

    util.makePath(CACHE_DIR)
    if util.directoryExists(CACHE_DIR) then
        return true
    end

    logger.warn("Annas:scraper - Could not create cache directory: " .. CACHE_DIR)
    return false
end

local function copy_file(source_path, target_path)
    local source = io.open(source_path, "rb")
    if not source then
        return false
    end

    local target = io.open(target_path, "wb")
    if not target then
        source:close()
        return false
    end

    local chunk = source:read("*a")
    if chunk then
        target:write(chunk)
    end

    source:close()
    target:close()
    return true
end

local function migrate_legacy_cache()
    if util.fileExists(CACHE_FILE) or not util.fileExists(LEGACY_CACHE_FILE) then
        return
    end

    if not ensure_cache_dir() then
        return
    end

    if copy_file(LEGACY_CACHE_FILE, CACHE_FILE) then
        logger.info("Annas:scraper - Migrated legacy domain cache to KOReader cache directory")
    else
        logger.warn("Annas:scraper - Failed to migrate legacy domain cache")
    end
end

local function get_cache_read_path()
    if util.fileExists(CACHE_FILE) then
        return CACHE_FILE
    end

    if util.fileExists(LEGACY_CACHE_FILE) then
        return LEGACY_CACHE_FILE
    end

    return CACHE_FILE
end

local function read_cache()
    migrate_legacy_cache()

    local cache_path = get_cache_read_path()
    local file = io.open(cache_path, "r")
    if not file then
        return nil, nil
    end

    local timestamp_str = file:read("*l")
    if not timestamp_str then
        file:close()
        return nil, nil
    end

    local timestamp = tonumber(timestamp_str)
    if not timestamp then
        file:close()
        return nil, nil
    end

    if os.time() - timestamp > CACHE_DURATION then
        file:close()
        logger.dbg("Annas:scraper - Domain cache expired at " .. cache_path)
        return nil, nil
    end

    local domains = {}
    for line in file:lines() do
        if line and line ~= "" then
            table.insert(domains, line)
        end
    end
    file:close()

    if #domains > 0 then
        logger.dbg(string.format("Annas:scraper - Loaded %d domains from cache", #domains))
        return domains, timestamp
    end

    return nil, nil
end

local function write_cache(domains)
    if not ensure_cache_dir() then
        return false
    end

    local file = io.open(CACHE_FILE, "w")
    if not file then
        logger.warn("Annas:scraper - Could not write domain cache file")
        return false
    end

    file:write(os.time() .. "\n")
    for _, domain in ipairs(domains) do
        file:write(domain .. "\n")
    end
    file:close()

    logger.dbg(string.format("Annas:scraper - Cached %d domains", #domains))
    return true
end

local function extract_domains_from_wikipedia(html)
    local domains = {}
    local seen = {}

    for url in html:gmatch('href="(https://annas%-archive%.[^/"]+)/?"') do
        local domain = url:match("https://(.+)")
        if domain and not seen[domain] then
            seen[domain] = true
            table.insert(domains, domain)
            logger.dbg("Annas:scraper - Found mirror domain: " .. domain)
        end
    end

    return domains
end

local function fetch_domains_from_wikipedia()
    local wikipedia_url = "https://en.wikipedia.org/wiki/Anna%27s_Archive"
    logger.info("Annas:scraper - Refreshing Anna mirror list from Wikipedia")

    local status, data = check_url(wikipedia_url, Config.getSearchTimeout())
    if status ~= "success" or not data then
        logger.warn("Annas:scraper - Failed to fetch Wikipedia mirror list: " .. tostring(status))
        return nil
    end

    local domains = extract_domains_from_wikipedia(data)
    if #domains == 0 then
        logger.warn("Annas:scraper - Wikipedia did not yield any Anna mirror domains")
        return nil
    end

    write_cache(domains)
    return domains
end

local function get_annas_archive_domains()
    local cached_domains, cache_time = read_cache()
    if cached_domains then
        local age_hours = math.floor((os.time() - cache_time) / 3600)
        logger.dbg(string.format("Annas:scraper - Using cached mirrors (age: %d hours)", age_hours))
        return cached_domains
    end

    local domains = fetch_domains_from_wikipedia()
    if domains and #domains > 0 then
        return domains
    end

    logger.warn("Annas:scraper - Falling back to built-in mirror list")
    return FALLBACK_DOMAINS
end

local function extract_md5_and_link(line)
    local md5 = line:match('href="/md5/([a-fA-F0-9]+)"')
    if md5 and #md5 == 32 then
        return md5
    end
    return nil
end

local function extract_title(line)
    local content = line:match('<div class="font%-bold text%-violet%-900 line%-clamp%-%[5%]" data%-content="([^"]+)"')
    if content then
        content = content:match("^%s*(.-)%s*$")
        content = content:gsub('"', '\\"')
        content = content:gsub("•", "\\u2022")
        logger.dbg("Annas:scraper - Parsed title: " .. content)
        return content
    end
    return "Could not retrieve title."
end

local function extract_author(line)
    if line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*"') then
        local block = line:match('<div[^>]*class="[^"]*font%-bold[^"]*text%-amber%-900[^"]*line%-clamp%-%[2%][^"]*" data%-content="[^"]+"')
        if block then
            local author = block:match('data%-content="([^"]+)"')
            if author then
                logger.dbg("Annas:scraper - Parsed author: " .. author)
                return author
            end
        end
    end
    return "Could not retrieve author."
end

local function extract_format(line)
    local div_text = line:match('<div class="text%-gray%-800[^>]*>[^<]+')
    if div_text then
        local content = div_text:match('>([^<]+)')
        if content then
            local format = content:match("([A-Z][A-Z]+)")
            if format then
                logger.dbg("Annas:scraper - Parsed format: " .. format)
                return format
            end
        end
    end
    return "Could not retrieve format."
end

local function extract_description(line)
    local div_block = line:match('<div[^>]*class="[^"]*line%-clamp%-%[2%][^"]*"[^>]*>(.-)</div>')
    if div_block then
        local description = div_block
        description = description:gsub('<script[^>]*>.-</script>', "")
        description = description:gsub('<a[^>]*>.-</a>', "")
        description = description:gsub('<[^>]+>', "")
        description = description:gsub('&[#a-zA-Z0-9]+;', "")
        description = description:gsub('^%s+', ""):gsub('%s+$', "")
        logger.dbg("Annas:scraper - Parsed description length: " .. tostring(#description))
        return description
    end
    return "Could not retrieve description."
end

local function resolve_timeout_seconds(timeout)
    if type(timeout) == "table" then
        if timeout[2] and timeout[2] > 0 then
            return timeout[2]
        end
        return timeout[1] or 20
    end

    if type(timeout) == "number" and timeout > 0 then
        return timeout
    end

    return 20
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
    if COMMAND_EXISTS_CACHE[cmd] ~= nil then
        return COMMAND_EXISTS_CACHE[cmd]
    end

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
            COMMAND_EXISTS_CACHE[cmd] = true
            return true
        end
    end

    COMMAND_EXISTS_CACHE[cmd] = false
    return false
end

local function command_close_succeeded(ok, exit_type, exit_code)
    return command_succeeded(ok, exit_type, exit_code)
end

local function classify_transport_error(detail)
    local text = tostring(detail or "")
    local lower = text:lower()

    if lower == "" then
        return "network_error"
    end

    if lower:find("could not resolve host", 1, true)
        or lower:find("name or service not known", 1, true)
        or lower:find("temporary failure in name resolution", 1, true)
        or lower:find("host not found", 1, true)
        or lower:find("dns", 1, true) then
        return "dns_error"
    end

    if lower:find("timeout", 1, true)
        or lower:find("timed out", 1, true)
        or lower:find("connection", 1, true)
        or lower:find("network", 1, true)
        or lower:find("tls", 1, true)
        or lower:find("ssl", 1, true)
        or lower:find("refused", 1, true)
        or lower:find("unreachable", 1, true) then
        return "network_error"
    end

    return "request_failed"
end

local function looks_like_html(payload)
    if type(payload) ~= "string" or payload == "" then
        return false
    end

    local head = payload:sub(1, 1024):lower()
    return head:find("<!doctype html", 1, true)
        or head:find("<html", 1, true)
        or head:find("<head", 1, true)
        or head:find("<body", 1, true)
end

local function detect_anti_bot_response(payload)
    if not looks_like_html(payload) then
        return false
    end

    local head = payload:sub(1, 4096):lower()
    for _, marker in ipairs(ANTI_BOT_MARKERS) do
        if head:find(marker, 1, true) then
            return true
        end
    end

    return false
end

local function fetch_with_api(url, timeout)
    logger.dbg("Annas:scraper - Trying Api.makeHttpRequest for " .. url)
    local hostname = url:match("://([^/]+)")
    local header_configs = {
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        },
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "en-US,en;q=0.5",
        },
        {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "en-US,en;q=0.5",
            ["Host"] = hostname,
        },
    }

    for _, headers in ipairs(header_configs) do
        local ok, http_result = pcall(function()
            return Api.makeHttpRequest{
                url = url,
                method = "GET",
                headers = headers,
                timeout = timeout,
            }
        end)

        if ok and http_result then
            local status_code = tonumber(http_result.status_code)
            if http_result.error then
                local detail = tostring(http_result.error)
                if status_code == 403 or status_code == 429 or status_code == 503 then
                    return "anti_bot", nil, detail
                end
                return classify_transport_error(detail), nil, detail
            end

            if status_code == 200 and http_result.body and #http_result.body > 0 then
                logger.dbg(string.format("Annas:scraper - Api request succeeded (%d bytes)", #http_result.body))
                return "success", http_result.body
            end
        end
    end

    return "network_error", nil, "Api.makeHttpRequest failed"
end

local function fetch_with_lua_socket(url)
    logger.dbg("Annas:scraper - Trying LuaSocket request for " .. url)

    local socket_ok = pcall(require, "socket")
    local http_ok, http = pcall(require, "socket.http")
    local ltn12_ok, ltn12 = pcall(require, "ltn12")

    if not (socket_ok and http_ok and ltn12_ok) then
        return "no_socket", nil, "LuaSocket not available"
    end

    local response_body = {}
    local res, code, _, status = http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        sink = ltn12.sink.table(response_body),
        redirect = true,
    }

    if res and code == 200 then
        local body = table.concat(response_body)
        logger.dbg(string.format("Annas:scraper - LuaSocket request succeeded (%d bytes)", #body))
        return "success", body
    end

    local detail = tostring(status or code or "LuaSocket request failed")
    logger.dbg("Annas:scraper - LuaSocket request failed: " .. detail)
    return classify_transport_error(detail), nil, detail
end

local function fetch_with_external_command(url, timeout)
    logger.dbg("Annas:scraper - Trying external HTTP fallback for " .. url)
    local max_time = resolve_timeout_seconds(timeout)

    if command_exists("curl") then
        local handle = io.popen(string.format('curl -L -sS --max-time %d "%s" 2>&1', max_time, url))
        if handle then
            local result = handle:read("*a") or ""
            local ok, exit_type, exit_code = handle:close()
            if command_close_succeeded(ok, exit_type, exit_code) and result ~= "" then
                logger.dbg(string.format("Annas:scraper - curl fallback succeeded (%d bytes)", #result))
                return "success", result
            end

            local detail = result ~= "" and result or "curl request failed"
            logger.dbg("Annas:scraper - curl fallback failed: " .. detail)
            return classify_transport_error(detail), nil, detail
        end
    end

    if command_exists("wget") then
        local temp_file = os.tmpname()
        local command = string.format('wget -q -O "%s" --timeout=%d "%s" 2>&1', temp_file, max_time, url)
        local handle = io.popen(command)
        if handle then
            local stderr = handle:read("*a") or ""
            local ok, exit_type, exit_code = handle:close()
            local file = io.open(temp_file, "rb")
            if file then
                local result = file:read("*a") or ""
                file:close()
                pcall(os.remove, temp_file)
                if command_close_succeeded(ok, exit_type, exit_code) and result ~= "" then
                    logger.dbg(string.format("Annas:scraper - wget fallback succeeded (%d bytes)", #result))
                    return "success", result
                end
            end

            pcall(os.remove, temp_file)
            local detail = stderr ~= "" and stderr or "wget request failed"
            logger.dbg("Annas:scraper - wget fallback failed: " .. detail)
            return classify_transport_error(detail), nil, detail
        end
    end

    return "no_external_command", nil, "curl/wget not available"
end

local function new_failure_stats()
    return {
        dns_error = 0,
        anti_bot = 0,
        mirror_error = 0,
        network_error = 0,
        request_failed = 0,
        last_detail = nil,
        last_mirror = nil,
    }
end

local function record_failure(stats, kind, detail, mirror)
    local key = kind
    if key ~= "dns_error" and key ~= "anti_bot" and key ~= "mirror_error" and key ~= "network_error" then
        key = "request_failed"
    end

    stats[key] = (stats[key] or 0) + 1
    stats.last_detail = detail
    stats.last_mirror = mirror
end

local function build_search_error_message(stats)
    if stats.dns_error > 0 then
        return T("Anna's Archive mirrors could not be resolved. Your DNS or network may be blocking the site. Try another DNS provider or network.")
    end

    if stats.anti_bot > 0 then
        return T("Anna's Archive mirrors are returning an anti-bot or DDoS protection page. Please wait and try again later.")
    end

    if stats.mirror_error > 0 then
        return T("Anna's Archive responded, but no mirror returned a usable search results page. Please try again later.")
    end

    return T("Unable to reach a working Anna's Archive mirror. Please check your connection and try again.")
end

local function build_download_error_message(stats)
    if stats.dns_error > 0 then
        return T("Download mirrors could not be resolved. Your DNS or network may be blocking the source mirror.")
    end

    if stats.anti_bot > 0 then
        return T("The selected mirror is returning an anti-bot or DDoS protection page instead of the file. Please try again later.")
    end

    if stats.mirror_error > 0 then
        return T("No working mirror returned a usable download file for this book. Please try again later.")
    end

    return T("Unable to reach a working download mirror. Please check your connection and try again.")
end

local function build_search_filters()
    local filters = ""
    local languages = Config.getSearchLanguages()
    local extensions = Config.getSearchExtensions()
    local order = Config.getSearchOrder()
    local source = "lgli"

    if languages then
        for _, language in pairs(languages) do
            filters = filters .. "&lang=" .. language
        end
    end

    if extensions then
        for _, extension in pairs(extensions) do
            filters = filters .. "&ext=" .. string.lower(extension)
        end
    end

    if order[1] then
        filters = filters .. "&sort=" .. order[1]
    end

    filters = filters .. "&src=" .. source
    return filters
end

local function parse_search_results(data, annas_url)
    local result_html = SEARCH_RESULT_SPLIT_PATTERN .. data
    local segments = {}
    local start_pos = 1

    while true do
        local s, e = result_html:find(SEARCH_RESULT_SPLIT_PATTERN, start_pos, true)
        if not s then
            break
        end

        local next_s = result_html:find(SEARCH_RESULT_SPLIT_PATTERN, e + 1, true)
        local segment
        if next_s then
            segment = result_html:sub(s, next_s - 1)
            start_pos = next_s
        else
            segment = result_html:sub(s)
            start_pos = #result_html + 1
        end

        table.insert(segments, segment)
    end

    local books = {}
    for _, entry in ipairs(segments) do
        local md5 = extract_md5_and_link(entry)
        if md5 then
            local book = {
                title = extract_title(entry),
                author = extract_author(entry),
                format = extract_format(entry),
                description = extract_description(entry),
                md5 = md5,
                link = annas_url .. "md5/" .. md5,
            }

            if string.find(entry, "lgli", 1, true) then
                book.download = "lgli"
                if string.find(entry, "zlib", 1, true) then
                    book.download = book.download .. " | zlib"
                end
            elseif string.find(entry, "zlib", 1, true) then
                book.download = "zlib"
            end

            local number_str = entry:match(" (%d+%.?%d*)MB . ") or entry:match(" (%d+%.?%d*)MB · ")
            if number_str then
                book.size = number_str .. "MB"
            end

            table.insert(books, book)
        end
    end

    logger.info(string.format("Annas:scraper - Parsed %d search results", #books))
    return books
end

function check_url(url, timeout)
    logger.dbg("Annas:scraper - check_url(" .. url .. ")")

    local failures = {}
    local methods = {
        fetch_with_api,
        fetch_with_lua_socket,
        fetch_with_external_command,
    }

    for _, fetcher in ipairs(methods) do
        local status, data, detail = fetcher(url, timeout)
        if status == "success" then
            return status, data
        end

        if status ~= "no_external_command" and status ~= "no_socket" then
            table.insert(failures, { status = status, detail = detail })
        end
    end

    for _, failure in ipairs(failures) do
        if failure.status == "dns_error" then
            return "dns_error", nil, failure.detail
        end
    end

    for _, failure in ipairs(failures) do
        if failure.status == "anti_bot" then
            return "anti_bot", nil, failure.detail
        end
    end

    local last_failure = failures[#failures]
    return "network_error", nil, last_failure and last_failure.detail or "All HTTP methods failed"
end

function scraper(query, page_number)
    local aa_domains = get_annas_archive_domains()
    local search_page = tostring(tonumber(page_number) or 1)
    local search_query = query or ""
    local encoded_query = string.gsub(search_query, " ", "+")
    local filters = build_search_filters()
    local timeout = Config.getSearchTimeout()
    local failures = new_failure_stats()

    logger.info(string.format("Annas:scraper - Starting search for \"%s\" on page %s", search_query, search_page))

    for _, domain in ipairs(aa_domains) do
        local annas_url = "https://" .. domain .. "/"
        local url = string.format("%ssearch?page=%s&q=%s%s", annas_url, search_page, encoded_query, filters)
        local status, data, detail = check_url(url, timeout)

        if status == "success" then
            if not data or data == "" then
                record_failure(failures, "mirror_error", "Empty search response", annas_url)
                logger.warn("Annas:scraper - Empty search response from " .. annas_url)
            elseif detect_anti_bot_response(data) then
                record_failure(failures, "anti_bot", "Anti-bot response body", annas_url)
                logger.warn("Annas:scraper - Anti-bot response from " .. annas_url)
            else
                return parse_search_results(data, annas_url)
            end
        else
            record_failure(failures, status, detail, annas_url)
            logger.warn(string.format("Annas:scraper - Search request failed on %s (%s)", annas_url, tostring(status)))
        end
    end

    local error_message = build_search_error_message(failures)
    logger.err("Annas:scraper - Search failed: " .. error_message)
    return nil, error_message
end

function sanitize_name(name)
    local sanitized = tostring(name or "unknown")
    sanitized = sanitized:gsub("[^%w._-]", "_")
    sanitized = sanitized:gsub(" ", "_")
    return sanitized
end

function save_file_bytes(path, bytes)
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, "open failed: " .. tostring(open_err)
    end

    local ok, write_err = file:write(bytes)
    file:close()
    if not ok then
        return nil, "write failed: " .. tostring(write_err)
    end

    return true, "saved file to: " .. path
end

function download_book(book, path)
    local lgli_exts = {
        ".la/",
        ".gl/",
        ".li/",
        ".is/",
        ".rs/",
        ".st/",
        ".bz/",
    }
    local timeout = Config.getDownloadTimeout()
    local failures = new_failure_stats()

    if not book.download then
        logger.warn("Annas:scraper - No download source available for book")
        return nil, T("No supported download mirror is available for this book.")
    end

    if not string.find(book.download, "lgli", 1, true) then
        logger.warn("Annas:scraper - Book is not available on a supported mirror: " .. tostring(book.download))
        return nil, T("This book is not available from a supported download mirror yet.")
    end

    local filename = path .. "/" .. sanitize_name(book.title) .. "_" .. sanitize_name(book.author) .. "." .. tostring(book.format or "bin")
    logger.info("Annas:scraper - Starting download for " .. tostring(book.title))

    for _, lgli_ext in ipairs(lgli_exts) do
        repeat
            local lgli_url = "https://libgen" .. lgli_ext
            local download_page = lgli_url .. "ads.php?md5=" .. tostring(book.md5 or "")
            local status, data, detail = check_url(download_page, timeout)

            if status ~= "success" then
                record_failure(failures, status, detail, lgli_url)
                logger.warn(string.format("Annas:scraper - Download page request failed on %s (%s)", lgli_url, tostring(status)))
                break
            end

            if not data or data == "" then
                record_failure(failures, "mirror_error", "Empty download page", lgli_url)
                logger.warn("Annas:scraper - Empty download page from " .. lgli_url)
                break
            end

            if detect_anti_bot_response(data) then
                record_failure(failures, "anti_bot", "Anti-bot response on download page", lgli_url)
                logger.warn("Annas:scraper - Anti-bot response on download page from " .. lgli_url)
                break
            end

            local download_link = data:match('href="([^"]*get%.php[^"]*)"')
            if not download_link then
                record_failure(failures, "mirror_error", "No file link on download page", lgli_url)
                logger.warn("Annas:scraper - No final download link found on " .. lgli_url)
                break
            end

            local download_url = lgli_url .. download_link
            local file_status, file_data, file_detail = check_url(download_url, timeout)
            if file_status ~= "success" then
                record_failure(failures, file_status, file_detail, download_url)
                logger.warn(string.format("Annas:scraper - File request failed on %s (%s)", download_url, tostring(file_status)))
                break
            end

            if not file_data or file_data == "" then
                record_failure(failures, "mirror_error", "Empty downloaded file", download_url)
                logger.warn("Annas:scraper - Empty file response from " .. download_url)
                break
            end

            if detect_anti_bot_response(file_data) then
                record_failure(failures, "anti_bot", "Anti-bot response instead of file", download_url)
                logger.warn("Annas:scraper - Anti-bot response instead of file from " .. download_url)
                break
            end

            if looks_like_html(file_data) then
                record_failure(failures, "mirror_error", "Mirror returned HTML instead of a file", download_url)
                logger.warn("Annas:scraper - Mirror returned HTML instead of a file: " .. download_url)
                break
            end

            local ok, save_err = save_file_bytes(filename, file_data)
            if not ok then
                logger.err("Annas:scraper - Failed to save downloaded file: " .. tostring(save_err))
                return nil, T("Failed to save downloaded file.")
            end

            logger.info("Annas:scraper - Download finished: " .. filename)
            return filename
        until true
    end

    local error_message = build_download_error_message(failures)
    logger.err("Annas:scraper - Download failed: " .. error_message)
    return nil, error_message
end

if ... == nil then
    logger.info("Annas:scraper - Running as main script")
    local books, err = scraper("Marx")
    if not books then
        logger.err("Annas:scraper - Standalone search failed: " .. tostring(err))
    end
end
