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
local SCRAPER_USER_AGENT = "KOReader-Annas-Plugin"

math.randomseed(os.time())

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
    local strategy = Config.getMirrorStrategy()
    local cached_domains, cache_time = read_cache()
    local discovered_domains = cached_domains

    if not discovered_domains then
        discovered_domains = fetch_domains_from_wikipedia()
    end

    local function merge_unique(primary, secondary)
        local merged = {}
        local seen = {}

        for _, domain in ipairs(primary or {}) do
            if domain and not seen[domain] then
                seen[domain] = true
                table.insert(merged, domain)
            end
        end

        for _, domain in ipairs(secondary or {}) do
            if domain and not seen[domain] then
                seen[domain] = true
                table.insert(merged, domain)
            end
        end

        return merged
    end

    local function shuffle_copy(values)
        local shuffled = {}
        for i, value in ipairs(values) do
            shuffled[i] = value
        end

        for i = #shuffled, 2, -1 do
            local j = math.random(i)
            shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
        end

        return shuffled
    end

    if discovered_domains and cache_time then
        local age_hours = math.floor((os.time() - cache_time) / 3600)
        logger.dbg(string.format("Annas:scraper - Using cached mirrors (age: %d hours)", age_hours))
    end

    if strategy == "builtin_first" then
        local domains = merge_unique(FALLBACK_DOMAINS, discovered_domains)
        if #domains > 0 then
            return domains
        end
    elseif strategy == "rotate" then
        local domains = merge_unique(discovered_domains, FALLBACK_DOMAINS)
        if #domains > 0 then
            return shuffle_copy(domains)
        end
    elseif discovered_domains and #discovered_domains > 0 then
        return discovered_domains
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
        debug_trace = {},
    }
end

local function append_debug_trace(stats, message)
    if type(stats) ~= "table" or type(message) ~= "string" or message == "" then
        return
    end

    stats.debug_trace = stats.debug_trace or {}
    if #stats.debug_trace >= 12 then
        return
    end

    local normalized = message:gsub("[\r\n]+", " "):gsub("%s+", " ")
    if #normalized > 120 then
        normalized = normalized:sub(1, 117) .. "..."
    end

    table.insert(stats.debug_trace, normalized)
end

local function build_debug_suffix(stats)
    if type(stats) ~= "table" or type(stats.debug_trace) ~= "table" or #stats.debug_trace == 0 then
        return ""
    end

    return "\n\nDebug: " .. table.concat(stats.debug_trace, " | ")
end

local function record_failure(stats, kind, detail, mirror)
    local key = kind
    if key ~= "dns_error" and key ~= "anti_bot" and key ~= "mirror_error" and key ~= "network_error" then
        key = "request_failed"
    end

    stats[key] = (stats[key] or 0) + 1
    stats.last_detail = detail
    stats.last_mirror = mirror

    local mirror_hint = tostring(mirror or "?")
    if #mirror_hint > 60 then
        mirror_hint = mirror_hint:sub(1, 57) .. "..."
    end

    local detail_hint = tostring(detail or "")
    if detail_hint ~= "" then
        detail_hint = detail_hint:gsub("[\r\n]+", " "):gsub("%s+", " ")
        if #detail_hint > 40 then
            detail_hint = detail_hint:sub(1, 37) .. "..."
        end
        append_debug_trace(stats, string.format("%s@%s:%s", key, mirror_hint, detail_hint))
    else
        append_debug_trace(stats, string.format("%s@%s", key, mirror_hint))
    end
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
    local source = Config.getSearchSource()

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

    if source ~= "all" then
        filters = filters .. "&src=" .. source
    end
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
            local providers = {}

            local function add_provider(provider_key)
                for _, existing in ipairs(providers) do
                    if existing == provider_key then
                        return
                    end
                end
                table.insert(providers, provider_key)
            end

            if string.find(entry, "lgli", 1, true) then
                add_provider("lgli")
            end
            if string.find(entry, "zlib", 1, true) then
                add_provider("zlib")
            end

            local provider_labels = {
                lgli = "LibGen",
                zlib = "Z-Library",
            }

            local provider_names = {}
            for _, provider_key in ipairs(providers) do
                table.insert(provider_names, provider_labels[provider_key] or provider_key)
            end

            local book = {
                title = extract_title(entry),
                author = extract_author(entry),
                format = extract_format(entry),
                description = extract_description(entry),
                md5 = md5,
                link = annas_url .. "md5/" .. md5,
                providers = providers,
                provider_label = #provider_names > 0 and table.concat(provider_names, " + ") or nil,
            }

            if #providers > 0 then
                book.download = table.concat(providers, " | ")
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

    local methods = {
        fetch_with_api,
        fetch_with_lua_socket,
        fetch_with_external_command,
    }
    local max_attempts = Config.getRetryCount() + 1

    local function resolve_failures(failures)
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

        for _, failure in ipairs(failures) do
            if failure.status == "request_failed" then
                return "request_failed", nil, failure.detail
            end
        end

        local last_failure = failures[#failures]
        return "network_error", nil, last_failure and last_failure.detail or "All HTTP methods failed"
    end

    for attempt = 1, max_attempts do
        local failures = {}

        for _, fetcher in ipairs(methods) do
            local status, data, detail = fetcher(url, timeout)
            if status == "success" then
                return status, data
            end

            if status ~= "no_external_command" and status ~= "no_socket" then
                table.insert(failures, { status = status, detail = detail })
            end
        end

        local status, _, detail = resolve_failures(failures)
        local should_retry = attempt < max_attempts and (status == "network_error" or status == "request_failed")
        if not should_retry then
            return status, nil, detail
        end

        logger.info(string.format("Annas:scraper - Retrying %s (%d/%d)", url, attempt + 1, max_attempts))
    end

    return "network_error", nil, "All HTTP methods failed"
end

local function update_cookie_jar(cookie_jar, headers)
    if type(cookie_jar) ~= "table" or type(headers) ~= "table" then
        return
    end

    local raw_set_cookie = headers["set-cookie"] or headers["Set-Cookie"]
    if not raw_set_cookie then
        return
    end

    local cookie_lines = {}
    if type(raw_set_cookie) == "string" then
        table.insert(cookie_lines, raw_set_cookie)
    elseif type(raw_set_cookie) == "table" then
        local has_indexed = false
        for _, value in ipairs(raw_set_cookie) do
            has_indexed = true
            if type(value) == "string" then
                table.insert(cookie_lines, value)
            end
        end

        if not has_indexed then
            for _, value in pairs(raw_set_cookie) do
                if type(value) == "string" then
                    table.insert(cookie_lines, value)
                end
            end
        end
    end

    for _, cookie_line in ipairs(cookie_lines) do
        local first_part = tostring(cookie_line):match("^%s*([^;]+)")
        if first_part then
            local name, value = first_part:match("^%s*([^=]+)=?(.*)$")
            if name and name ~= "" then
                local normalized_name = name:gsub("^%s+", ""):gsub("%s+$", "")
                local normalized_value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if normalized_value == "" or normalized_value:lower() == "deleted" then
                    cookie_jar[normalized_name] = nil
                else
                    cookie_jar[normalized_name] = normalized_value
                end
            end
        end
    end
end

local function build_cookie_header(cookie_jar)
    if type(cookie_jar) ~= "table" then
        return nil
    end

    local pairs_list = {}
    for cookie_name, cookie_value in pairs(cookie_jar) do
        if cookie_name and cookie_name ~= "" and cookie_value and cookie_value ~= "" then
            table.insert(pairs_list, tostring(cookie_name) .. "=" .. tostring(cookie_value))
        end
    end

    if #pairs_list == 0 then
        return nil
    end

    table.sort(pairs_list)
    return table.concat(pairs_list, "; ")
end

local function check_url_with_cookie_session(url, timeout, cookie_jar)
    local request_headers = {
        ["User-Agent"] = SCRAPER_USER_AGENT,
    }

    local cookie_header = build_cookie_header(cookie_jar)
    if cookie_header then
        request_headers["Cookie"] = cookie_header
    end

    local response = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = request_headers,
        timeout = timeout,
    }

    if type(response) == "table" then
        update_cookie_jar(cookie_jar, response.headers)
    end

    if type(response) == "table" and not response.error
        and (response.status_code == 200 or response.status_code == 206)
        and response.body and response.body ~= "" then
        return "success", response.body
    end

    local detail = type(response) == "table"
        and tostring(response.error or response.status_code or "request failed")
        or "request failed"

    return classify_transport_error(detail), nil, detail
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

local function get_book_providers(book)
    local providers = {}
    local seen = {}

    local function add_provider(provider_key)
        if provider_key and provider_key ~= "" and not seen[provider_key] then
            seen[provider_key] = true
            table.insert(providers, provider_key)
        end
    end

    if type(book.providers) == "table" then
        for _, provider_key in ipairs(book.providers) do
            add_provider(provider_key)
        end
    end

    local download_text = tostring(book.download or "")
    if download_text:find("lgli", 1, true) then
        add_provider("lgli")
    end
    if download_text:find("zlib", 1, true) then
        add_provider("zlib")
    end

    return providers
end

local function sleep_seconds(seconds)
    local wait_seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if wait_seconds <= 0 then
        return
    end

    local socket_ok, socket_mod = pcall(require, "socket")
    if socket_ok and socket_mod and socket_mod.sleep then
        socket_mod.sleep(wait_seconds)
        return
    end

    local shell_wait_ok = false
    if IS_WINDOWS then
        local execute_result = os.execute(string.format('powershell -Command "Start-Sleep -Seconds %d"', wait_seconds))
        shell_wait_ok = (execute_result == true or execute_result == 0)
    else
        local execute_result = os.execute(string.format("sleep %d", wait_seconds))
        shell_wait_ok = (execute_result == true or execute_result == 0)
    end

    if shell_wait_ok then
        return
    end

    -- Final fallback for restricted runtimes where os.execute is disabled.
    local start_time = os.time()
    while os.difftime(os.time(), start_time) < wait_seconds do
    end
end

local function normalize_extracted_url(url)
    if not url then
        return nil
    end

    local normalized = tostring(url)
    normalized = normalized:gsub("&amp;", "&")
    normalized = normalized:gsub("^[%s\"']+", "")
    normalized = normalized:gsub("[%s\"'>)]+$", "")
    return normalized
end

local function build_absolute_url(base_url, candidate_url)
    if not candidate_url or candidate_url == "" then
        return nil
    end

    local normalized = normalize_extracted_url(candidate_url)
    if normalized:match("^https?://") then
        return normalized
    end

    local base_origin = tostring(base_url):match("^(https?://[^/]+)")
    if not base_origin then
        return normalized
    end

    if normalized:sub(1, 2) == "//" then
        local scheme = tostring(base_url):match("^(https?):") or "https"
        return scheme .. ":" .. normalized
    end

    if normalized:sub(1, 1) == "/" then
        return base_origin .. normalized
    end

    local base_dir = tostring(base_url):match("^(https?://.*/)") or (base_origin .. "/")
    return base_dir .. normalized
end

local function iterate_href_values(html, callback)
    for raw_url in html:gmatch('href%s*=%s*"([^"]+)"') do
        callback(raw_url)
    end

    for raw_url in html:gmatch("href%s*=%s*'([^']+)'") do
        callback(raw_url)
    end
end

local function extract_slow_partner_links(html, base_url)
    if type(html) ~= "string" or html == "" then
        return {}
    end

    local links = {}
    local seen = {}

    local function add_link(raw_url)
        local absolute = build_absolute_url(base_url, raw_url)
        if not absolute then
            return
        end

        if not seen[absolute] then
            seen[absolute] = true
            table.insert(links, absolute)
        end
    end

    iterate_href_values(html, function(raw_url)
        local lower = tostring(raw_url):lower()
        if lower:find("/slow_download/", 1, true) then
            add_link(raw_url)
        end
    end)

    for raw_url in html:gmatch('href="([^"]+)"[^>]->%s*[Ss]low%s+[Pp]artner%s+[Ss]erver') do
        add_link(raw_url)
    end

    for raw_url in html:gmatch('href="([^"]+)".-[Ss]low%s+[Pp]artner%s+[Ss]erver') do
        add_link(raw_url)
    end

    for raw_url in html:gmatch("href='([^']+)'[^>]->%s*[Ss]low%s+[Pp]artner%s+[Ss]erver") do
        add_link(raw_url)
    end

    for raw_url in html:gmatch("href='([^']+)'.-[Ss]low%s+[Pp]artner%s+[Ss]erver") do
        add_link(raw_url)
    end

    if #links == 0 then
        iterate_href_values(html, function(raw_url)
            local lower = tostring(raw_url):lower()
            if lower:find("/slow", 1, true)
                or lower:find("slow_partner", 1, true)
                or lower:find("slow-partner", 1, true)
                or (lower:find("partner", 1, true) and lower:find("download", 1, true))
                or lower:find("waitlist", 1, true) then
                add_link(raw_url)
            end
        end)
    end

    return links
end

local function extract_partner_download_links(html, base_url)
    if type(html) ~= "string" or html == "" then
        return {}
    end

    local links = {}
    local seen = {}

    local function add_link(raw_url)
        local absolute = build_absolute_url(base_url, raw_url)
        if absolute and not seen[absolute] then
            seen[absolute] = true
            table.insert(links, absolute)
        end
    end

    for raw_url in html:gmatch('href="([^"]+)"[^>]->%s*[Dd]ownload%s+from%s+partner%s+website') do
        add_link(raw_url)
    end

    for raw_url in html:gmatch("href='([^']+)'[^>]->%s*[Dd]ownload%s+from%s+partner%s+website") do
        add_link(raw_url)
    end

    if #links == 0 then
        iterate_href_values(html, function(raw_url)
            local lower = tostring(raw_url):lower()
            if (lower:find("partner", 1, true) and lower:find("download", 1, true))
                or lower:find("download-from-partner", 1, true)
                or lower:find("/slow", 1, true)
                or lower:find("waitlist", 1, true) then
                add_link(raw_url)
            end
        end)
    end

    return links
end

local function parse_wait_seconds(html)
    if type(html) ~= "string" or html == "" then
        return nil
    end

    local js_wait_seconds = html:match("waitSeconds%s*=%s*(%d+)")
        or html:match("wait_seconds%s*=%s*(%d+)")
        or html:match("[Ww]ait%s*[Ss]econds%s*[:=]%s*(%d+)")
    if js_wait_seconds then
        local parsed_js_seconds = tonumber(js_wait_seconds)
        if parsed_js_seconds and parsed_js_seconds > 0 then
            return parsed_js_seconds
        end
    end

    local dom_wait_seconds = html:match("js%-partner%-countdown[^>]*>%s*(%d+)%s*<")
        or html:match("[Pp]lease%s*wait%s*<span[^>]*>%s*(%d+)%s*</span>%s*seconds")
        or html:match("(%d+)%s*seconds%s*to%s*download")
    if dom_wait_seconds then
        local parsed_dom_seconds = tonumber(dom_wait_seconds)
        if parsed_dom_seconds and parsed_dom_seconds > 0 then
            return parsed_dom_seconds
        end
    end

    local text_only = html:gsub("<[^>]+>", " ")
    text_only = text_only:gsub("&nbsp;", " ")
    text_only = text_only:gsub("%s+", " ")

    local raw_seconds = text_only:match("[Pp]lease%s+wait%s+(%d+)%s+seconds")
        or text_only:match("wait%s+(%d+)%s+seconds%s+to%s+download")
        or text_only:match("(%d+)%s+seconds%s+to%s+download")

    local wait_seconds = tonumber(raw_seconds)
    if wait_seconds and wait_seconds > 0 then
        return wait_seconds
    end

    return nil
end

local function extract_copy_download_url(html)
    if type(html) ~= "string" or html == "" then
        return nil
    end

    local candidates = {}
    local seen = {}

    local function push_candidate(url)
        local normalized = normalize_extracted_url(url)
        if normalized and normalized:match("^https?://") and not seen[normalized] then
            seen[normalized] = true
            table.insert(candidates, normalized)
        end
    end

    local function looks_like_download_candidate(url)
        local lower = tostring(url):lower()
        local host = lower:match("^https?://([^/%?#]+)") or ""
        local path = lower:match("^https?://[^/%?#]+([^?#]*)") or ""

        if host == "" then
            return false
        end

        if host:find("github.com", 1, true)
            or host:find("raw.githubusercontent.com", 1, true)
            or host:find("darkreader.org", 1, true)
            or host:find("wikipedia.org", 1, true) then
            return false
        end

        if path:find("/slow_download/", 1, true)
            or path:find("/fast_download/", 1, true) then
            return false
        end

        local has_known_marker = lower:find("books-files", 1, true)
            or lower:find("/redirection?", 1, true)
            or lower:find("annas_archive_data__aacid", 1, true)
            or lower:find("aacid__", 1, true)
            or lower:find("annas-arch-", 1, true)
            or lower:find("zlib3_files", 1, true)
            or lower:find("filename=", 1, true)

        local has_file_extension = lower:match("%.epub([%?&].*)?$")
            or lower:match("%.pdf([%?&].*)?$")
            or lower:match("%.mobi([%?&].*)?$")
            or lower:match("%.azw3?([%?&].*)?$")
            or lower:match("%.fb2([%?&].*)?$")
            or lower:match("%.djvu?([%?&].*)?$")
            or lower:match("%.cbz([%?&].*)?$")
            or lower:match("%.cbr([%?&].*)?$")
            or lower:match("%.txt([%?&].*)?$")
            or lower:match("%.zip([%?&].*)?$")
            or lower:match("%.7z([%?&].*)?$")
            or lower:match("%.rar([%?&].*)?$")

        return has_known_marker or has_file_extension
    end

    local function score_candidate(url)
        if not looks_like_download_candidate(url) then
            return -1000
        end

        local lower = tostring(url):lower()
        local score = 0

        if lower:find("books-files", 1, true) then
            score = score + 90
        end
        if lower:find("/redirection?", 1, true) then
            score = score + 80
        end
        if lower:find("annas_archive_data__aacid", 1, true) then
            score = score + 70
        end
        if lower:find("aacid__", 1, true) then
            score = score + 45
        end
        if lower:find("annas-arch-", 1, true) then
            score = score + 40
        end
        if lower:find("zlib3_files", 1, true) then
            score = score + 30
        end
        if lower:find("filename=", 1, true) then
            score = score + 25
        end

        if lower:match("%.epub([%?&].*)?$")
            or lower:match("%.pdf([%?&].*)?$")
            or lower:match("%.mobi([%?&].*)?$")
            or lower:match("%.azw3?([%?&].*)?$")
            or lower:match("%.fb2([%?&].*)?$")
            or lower:match("%.djvu?([%?&].*)?$")
            or lower:match("%.cbz([%?&].*)?$")
            or lower:match("%.txt([%?&].*)?$") then
            score = score + 35
        end

        return score
    end

    for copied_url in html:gmatch("copy%s*(https?://[^%s<\"']+)") do
        push_candidate(copied_url)
    end

    for copied_url in html:gmatch("writeText%s*%(%s*['\"](https?://[^'\"]+)['\"]%s*%)") do
        push_candidate(copied_url)
    end

    for candidate in html:gmatch("https?://[^%s<\"']+") do
        push_candidate(candidate)
    end

    local best_url = nil
    local best_score = -1000
    for _, candidate in ipairs(candidates) do
        local score = score_candidate(candidate)
        if score > best_score then
            best_score = score
            best_url = candidate
        end
    end

    if best_url and best_score > 0 then
        logger.info(string.format("Annas:scraper - Selected direct link candidate (score=%d): %s", best_score, best_url))
        return best_url
    end

    return nil
end

local function attempt_file_download(download_url, filename, timeout, failures, cookie_jar)
    local file_status
    local file_data
    local file_detail

    if type(cookie_jar) == "table" then
        file_status, file_data, file_detail = check_url_with_cookie_session(download_url, timeout, cookie_jar)
        if file_status ~= "success" then
            logger.dbg(string.format("Annas:scraper - Session request failed on %s (%s), trying generic methods", download_url, tostring(file_status)))
            local fallback_status, fallback_data, fallback_detail = check_url(download_url, timeout)
            if fallback_status == "success" then
                file_status, file_data, file_detail = fallback_status, fallback_data, fallback_detail
            end
        end
    else
        file_status, file_data, file_detail = check_url(download_url, timeout)
    end

    if file_status ~= "success" then
        record_failure(failures, file_status, file_detail, download_url)
        logger.warn(string.format("Annas:scraper - File request failed on %s (%s)", download_url, tostring(file_status)))
        return nil
    end

    if not file_data or file_data == "" then
        record_failure(failures, "mirror_error", "Empty downloaded file", download_url)
        logger.warn("Annas:scraper - Empty file response from " .. download_url)
        return nil
    end

    if detect_anti_bot_response(file_data) then
        record_failure(failures, "anti_bot", "Anti-bot response instead of file", download_url)
        logger.warn("Annas:scraper - Anti-bot response instead of file from " .. download_url)
        return nil
    end

    if looks_like_html(file_data) then
        record_failure(failures, "mirror_error", "Mirror returned HTML instead of a file", download_url)
        logger.warn("Annas:scraper - Mirror returned HTML instead of a file: " .. download_url)
        return nil
    end

    local ok, save_err = save_file_bytes(filename, file_data)
    if not ok then
        logger.err("Annas:scraper - Failed to save downloaded file: " .. tostring(save_err))
        return nil, T("Failed to save downloaded file.")
    end

    logger.info("Annas:scraper - Download finished: " .. filename)
    return filename
end

local function try_lgli_download(book, filename, timeout, failures)
    local lgli_exts = {
        ".la/",
        ".gl/",
        ".li/",
        ".is/",
        ".rs/",
        ".st/",
        ".bz/",
    }

    local preferred_source = Config.getPreferredSource()

    if preferred_source ~= "auto" then
        local preferred_ext = "." .. preferred_source .. "/"
        local reordered_exts = { preferred_ext }
        for _, ext in ipairs(lgli_exts) do
            if ext ~= preferred_ext then
                table.insert(reordered_exts, ext)
            end
        end
        lgli_exts = reordered_exts
    end

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
            local downloaded_file, save_err = attempt_file_download(download_url, filename, timeout, failures)
            if downloaded_file then
                return downloaded_file
            end

            if save_err then
                return nil, save_err
            end
        until true
    end

    return nil
end

local function try_anna_slow_download(book, filename, timeout, failures)
    local detail_url = tostring(book.link or "")
    if detail_url == "" then
        record_failure(failures, "mirror_error", "Missing Anna detail page URL", "annas")
        return nil
    end

    local seen_pages = {}
    local cookie_jar = {}

    local function short_url(url)
        local value = tostring(url or "?")
        if #value > 80 then
            return value:sub(1, 77) .. "..."
        end
        return value
    end

    local function trace(message)
        append_debug_trace(failures, "anna:" .. tostring(message or ""))
    end

    trace("detail=" .. short_url(detail_url))

    local function fetch_html_page(page_url, page_label)
        local status, data, detail = check_url_with_cookie_session(page_url, timeout, cookie_jar)
        if status ~= "success" then
            local fallback_status, fallback_data, fallback_detail = check_url(page_url, timeout)
            if fallback_status == "success" then
                status, data, detail = fallback_status, fallback_data, fallback_detail
            end
        end

        if status ~= "success" then
            record_failure(failures, status, detail, page_url)
            logger.warn(string.format("Annas:scraper - %s request failed on %s (%s)", page_label, page_url, tostring(status)))
            trace(string.format("%s fail:%s", page_label, tostring(status)))
            return nil
        end

        if not data or data == "" then
            record_failure(failures, "mirror_error", "Empty page response", page_url)
            logger.warn("Annas:scraper - Empty page response from " .. page_url)
            trace(page_label .. " empty")
            return nil
        end

        if detect_anti_bot_response(data) then
            record_failure(failures, "anti_bot", "Anti-bot response on page", page_url)
            logger.warn("Annas:scraper - Anti-bot response on page: " .. page_url)
            trace(page_label .. " anti-bot")
            return nil
        end

        trace(page_label .. " ok")

        return data
    end

    local function try_download_from_direct_link(direct_url)
        if not direct_url then
            trace("direct:none")
            return nil
        end

        trace("direct=" .. short_url(direct_url))
        local downloaded_file, save_err = attempt_file_download(direct_url, filename, timeout, failures, cookie_jar)
        if downloaded_file then
            return downloaded_file
        end

        if save_err then
            return nil, save_err
        end

        return nil
    end

    local function try_slow_link_page(slow_link)
        if seen_pages[slow_link] then
            return nil
        end
        seen_pages[slow_link] = true
        trace("slow=" .. short_url(slow_link))

        local page_data = fetch_html_page(slow_link, "Slow partner page")
        if not page_data then
            return nil
        end

        local direct_url = extract_copy_download_url(page_data)
        local downloaded_file, save_err = try_download_from_direct_link(direct_url)
        if downloaded_file or save_err then
            return downloaded_file, save_err
        end

        local wait_seconds = parse_wait_seconds(page_data)
        if wait_seconds and wait_seconds > 0 then
            trace("wait=" .. tostring(wait_seconds))
            local bounded_wait = math.min(wait_seconds + 1, 45)
            logger.info(string.format("Annas:scraper - Waiting %ds for Anna slow partner link", bounded_wait))
            sleep_seconds(bounded_wait)

            local waited_data = fetch_html_page(slow_link, "Slow partner page refresh")
            if waited_data then
                local waited_direct_url = extract_copy_download_url(waited_data)
                downloaded_file, save_err = try_download_from_direct_link(waited_direct_url)
                if downloaded_file or save_err then
                    return downloaded_file, save_err
                end
            end
        else
            trace("wait=none")

            -- Some mirrors omit visible countdown text; try timed refresh retries anyway.
            local fallback_waits = { 8, 12 }
            for _, fallback_wait in ipairs(fallback_waits) do
                trace("retry_wait=" .. tostring(fallback_wait))
                sleep_seconds(fallback_wait)

                local retried_data = fetch_html_page(slow_link, "Slow partner fallback refresh")
                if retried_data then
                    local retry_direct_url = extract_copy_download_url(retried_data)
                    downloaded_file, save_err = try_download_from_direct_link(retry_direct_url)
                    if downloaded_file or save_err then
                        return downloaded_file, save_err
                    end
                end
            end
        end

        record_failure(failures, "mirror_error", "No final direct link found on Anna slow page", slow_link)
        logger.warn("Annas:scraper - No final direct URL found on Anna slow page: " .. slow_link)
        return nil
    end

    local function try_page(page_url, allow_partner_hop)
        if seen_pages[page_url] then
            return nil
        end
        seen_pages[page_url] = true

        local page_data = fetch_html_page(page_url, "Anna page")
        if not page_data then
            return nil
        end

        local direct_url = extract_copy_download_url(page_data)
        local downloaded_file, save_err = try_download_from_direct_link(direct_url)
        if downloaded_file or save_err then
            return downloaded_file, save_err
        end

        local slow_links = extract_slow_partner_links(page_data, page_url)
        logger.info(string.format("Annas:scraper - Found %d slow-link candidates on %s", #slow_links, page_url))
        trace("slow_candidates=" .. tostring(#slow_links))
        for _, slow_link in ipairs(slow_links) do
            downloaded_file, save_err = try_slow_link_page(slow_link)
            if downloaded_file or save_err then
                return downloaded_file, save_err
            end
        end

        if allow_partner_hop then
            local partner_links = extract_partner_download_links(page_data, page_url)
            logger.info(string.format("Annas:scraper - Found %d partner-page candidates on %s", #partner_links, page_url))
            trace("partner_candidates=" .. tostring(#partner_links))
            for _, partner_link in ipairs(partner_links) do
                trace("partner=" .. short_url(partner_link))
                downloaded_file, save_err = try_page(partner_link, false)
                if downloaded_file or save_err then
                    return downloaded_file, save_err
                end
            end
        end

        return nil
    end

    return try_page(detail_url, true)
end

function download_book(book, path)
    local timeout = Config.getDownloadTimeout()
    local failures = new_failure_stats()
    local providers = get_book_providers(book)

    if #providers == 0 then
        logger.warn("Annas:scraper - No supported provider key found for book")
        return nil, T("No supported download mirror is available for this book.")
    end

    local has_lgli = false
    local has_zlib = false
    for _, provider_key in ipairs(providers) do
        if provider_key == "lgli" then
            has_lgli = true
        elseif provider_key == "zlib" then
            has_zlib = true
        end
    end

    local filename = path .. "/" .. sanitize_name(book.title) .. "_" .. sanitize_name(book.author) .. "." .. tostring(book.format or "bin")
    logger.info(string.format("Annas:scraper - Starting download for %s (providers: %s)", tostring(book.title), table.concat(providers, ", ")))

    if has_lgli then
        local downloaded_file, save_err = try_lgli_download(book, filename, timeout, failures)
        if downloaded_file then
            return downloaded_file
        end

        if save_err then
            return nil, save_err
        end
    end

    if has_zlib then
        local downloaded_file, save_err = try_anna_slow_download(book, filename, timeout, failures)
        if downloaded_file then
            return downloaded_file
        end

        if save_err then
            return nil, save_err
        end
    end

    local debug_suffix = has_zlib and build_debug_suffix(failures) or ""

    if has_zlib and not has_lgli
        and failures.mirror_error > 0
        and failures.network_error == 0
        and failures.request_failed == 0
        and failures.anti_bot == 0 then
        return nil, T("Could not resolve a usable Anna slow-download link for this Z-Library item. Try opening the Anna page in a browser first, then retry.") .. debug_suffix
    end

    local error_message = build_download_error_message(failures)
    if debug_suffix ~= "" then
        error_message = error_message .. debug_suffix
    end
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
