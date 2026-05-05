-- Copyright 2025 Drfccv
-- Licensed under the MIT License

module("luci.controller.openlistui", package.seeall)

local nixio = require "nixio"
local uci = require "luci.model.uci".cursor()
local sys = require "luci.sys"
local http = require "luci.http"
local util = require "luci.util"
local fs = require "nixio.fs"
local i18n = require "luci.i18n"

-- Forward declarations removed - functions defined before use

-- Essential functions defined first to avoid nil value errors

-- Module initialization check - defined immediately after module declaration
function check_module_functions()
    local required_functions = {
        "log_openlistui_operation",
        "get_system_arch", 
        "get_kernel_save_path",
        "ensure_config_exists",
        "detect_and_set_kernel_path"
    }
    
    for _, func_name in ipairs(required_functions) do
        if not _G[func_name] then
            log_openlistui_operation("MODULE_ERROR", "Function " .. func_name .. " not defined")
            return false
        end
    end
    return true
end

-- Helper function to log OpenListUI operations
function log_openlistui_operation(action, details)
    local enable_logging = uci:get("openlistui", "main", "enable_logging") or "1"
    
    if enable_logging == "1" then
        local log_file = uci:get("openlistui", "main", "log_file") or "/var/log/openlistui.log"
        local log_max_size = tonumber(uci:get("openlistui", "main", "log_max_size") or "4")
        local log_cache_hours = tonumber(uci:get("openlistui", "main", "log_cache_hours") or "48")
        
        -- Ensure log directory exists
        local log_dir = log_file:match("(.+)/[^/]+$")
        if log_dir then
            sys.exec("mkdir -p '" .. log_dir .. "' 2>/dev/null")
        end
        
        -- Check log file size and rotate if necessary
        local file_size = sys.exec("stat -c%s '" .. log_file .. "' 2>/dev/null || echo 0")
        file_size = tonumber(file_size) or 0
        local max_size_bytes = log_max_size * 1024 * 1024
        
        if file_size > max_size_bytes then
            -- Rotate log file
            sys.exec("tail -n 1000 '" .. log_file .. "' > '" .. log_file .. ".tmp' 2>/dev/null && mv '" .. log_file .. ".tmp' '" .. log_file .. "' 2>/dev/null")
        end
        
        -- Clean old log entries based on cache hours (keep only recent entries)
        if log_cache_hours > 0 then
            local cache_lines = math.max(100, log_cache_hours * 10) -- Estimate lines to keep
            sys.exec("tail -n " .. cache_lines .. " '" .. log_file .. "' > '" .. log_file .. ".tmp' 2>/dev/null && mv '" .. log_file .. ".tmp' '" .. log_file .. "' 2>/dev/null")
        end
        
        -- Write to log file with error checking
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        local write_result = sys.call("echo '[" .. timestamp .. "] [" .. action .. "] " .. details .. "' >> '" .. log_file .. "' 2>/dev/null")
        
        -- If file write fails, fallback to system logger
        if write_result ~= 0 then
            sys.exec("logger -t openlistui '[FALLBACK] [" .. action .. "] " .. details .. "'")
        end
    else
        -- Fallback to system logger if logging is disabled
        sys.exec("logger -t openlistui '[" .. action .. "] " .. details .. "'")
    end
end

-- Get system architecture
function get_system_arch()
    local arch = util.trim(sys.exec("uname -m"))
    if arch == "x86_64" then
        return "linux-musl-amd64"
    elseif arch == "aarch64" then
        return "linux-musl-arm64"
    elseif arch == "armv7l" then
        return "linux-musleabihf-armv7l"
    elseif arch == "armv6l" then
        return "linux-musleabihf-armv6"
    elseif arch == "mips" then
        return "linux-musl-mips"
    elseif arch == "mipsel" then
        return "linux-musl-mipsle"
    else
        return "linux-musl-amd64"  -- fallback
    end
end

-- Get kernel save location from UCI configuration
function get_kernel_save_path()
    local save_path = uci:get("openlistui", "integration", "kernel_save_path")
    if not save_path or save_path == "" then
        save_path = "/tmp/openlist"  -- Default fallback
    end
    
    -- Ensure directory exists
    if save_path then
        sys.exec("mkdir -p '" .. save_path .. "' 2>/dev/null")
    end
    
    return save_path
end

-- Ensure configuration file exists with default values
function ensure_config_exists()
    local config_file = "/etc/config/openlistui"
    local default_arch = get_system_arch() or "linux-amd64"
    
    -- Only create config file if it doesn't exist at all
    if not fs.access(config_file) then
        -- Create config file with default content
        local config_content = [[
config openlistui 'main'
	option enabled '1'
	option port '5244'
	option data_dir '/etc/openlistui'
	option admin_password ''
	option auto_start '0'
	option enable_https '0'
	option cert_file ''
	option key_file ''


	option password 'admin'

config openlistui 'integration'
	option kernel_save_path '/tmp/openlist'
	option target_arch ']] .. default_arch .. [['
	option release_branch 'master'
	option core_type 'full'
]]
        
        -- Write config file
        local file = io.open(config_file, "w")
        if file then
            file:write(config_content)
            file:close()
            sys.exec("chmod 644 " .. config_file)
            log_openlistui_operation("CONFIG_CREATE", "Created default configuration file")
        else
            log_openlistui_operation("CONFIG_ERROR", "Failed to create configuration file")
        end
    end
    
    -- Ensure required sections exist via UCI (safer than file access)
    -- Only create sections if they don't exist, preserve existing values
    if not uci:get("openlistui", "main") then
        uci:set("openlistui", "main", "openlistui")
        uci:set("openlistui", "main", "enabled", "1")
        uci:set("openlistui", "main", "port", "5244")
        uci:set("openlistui", "main", "data_dir", "/etc/openlistui")
        uci:set("openlistui", "main", "auto_start", "1")
    else
        -- Ensure required options exist without overwriting existing values
        if not uci:get("openlistui", "main", "enabled") then
            uci:set("openlistui", "main", "enabled", "1")
        end
        if not uci:get("openlistui", "main", "port") then
            uci:set("openlistui", "main", "port", "5244")
        end
        if not uci:get("openlistui", "main", "data_dir") then
            uci:set("openlistui", "main", "data_dir", "/etc/openlistui")
        end
        if not uci:get("openlistui", "main", "auto_start") then
            uci:set("openlistui", "main", "auto_start", "0")
        end
    end
    
    if not uci:get("openlistui", "integration") then
        uci:set("openlistui", "integration", "openlistui")
        uci:set("openlistui", "integration", "kernel_save_path", "/tmp/openlist")
        uci:set("openlistui", "integration", "target_arch", default_arch)
        uci:set("openlistui", "integration", "release_branch", "master")
        uci:set("openlistui", "integration", "core_type", "full")
    else
        -- Ensure required options exist without overwriting existing values
        if not uci:get("openlistui", "integration", "kernel_save_path") then
            uci:set("openlistui", "integration", "kernel_save_path", "/tmp/openlist")
        end
        if not uci:get("openlistui", "integration", "target_arch") then
            uci:set("openlistui", "integration", "target_arch", default_arch)
        end
        if not uci:get("openlistui", "integration", "release_branch") then
            uci:set("openlistui", "integration", "release_branch", "master")
        end
        if not uci:get("openlistui", "integration", "core_type") then
            uci:set("openlistui", "integration", "core_type", "full")
        end
    end
    
    -- Commit changes
    uci:commit("openlistui")
end

-- Detect and set kernel save path if OpenList binary is found
function detect_and_set_kernel_path()
    local common_paths = {
        "/usr/bin/openlist",
        "/usr/local/bin/openlist",
        "/opt/bin/openlist",
        "/tmp/openlist/openlist",
        "/etc/openlistui/openlist",
        "/usr/share/openlistui/openlist",
        "./openlist"
    }
    
    -- Check current configured path first
    local current_save_path = get_kernel_save_path()
    local current_binary = current_save_path .. "/openlist"
    if fs.access(current_binary) then
        return current_binary, current_save_path
    end
    
    -- Search common paths
    for _, path in ipairs(common_paths) do
        if fs.access(path) then
            local dir_path = path:match("^(.+)/[^/]+$") or "/"
            -- Only update UCI if not currently set or different
            local current_config = uci:get("openlistui", "integration", "kernel_save_path")
            if not current_config or current_config ~= dir_path then
                ensure_config_exists()  -- Ensure config exists before setting
                uci:set("openlistui", "integration", "kernel_save_path", dir_path)
                uci:commit("openlistui")
            end
            return path, dir_path
        end
    end
    
    -- No binary found, return nil
    return nil, nil
end

-- GitHub API Cache management
local github_cache = {}
local cache_ttl = 43200  -- 12 hours cache TTL (12 * 60 * 60 = 43200 seconds)

-- Get proxy settings from UCI
function get_proxy_settings()
    local proxy_url = uci:get("openlistui", "integration", "github_proxy")
    if proxy_url and proxy_url ~= "" and not proxy_url:match("^%s*$") then
        return proxy_url
    end
    return nil
end

-- Get GitHub token from UCI for API authentication
function get_github_token()
    local token = uci:get("openlistui", "integration", "github_token")
    if token and token ~= "" and not token:match("^%s*$") then
        return token
    end
    return nil
end

-- Apply proxy to GitHub URLs (only for file downloads, not API calls)
function apply_proxy_to_url(url)
    local proxy = get_proxy_settings()
    if not proxy or proxy == "" then
        -- No proxy configured, return original URL
        return url
    end
    
    -- Remove trailing slash from proxy if present
    proxy = proxy:gsub("/$", "")
    
    -- Only apply proxy to file download URLs, not API endpoints
    local should_proxy = false
    
    if url:match("raw%.githubusercontent%.com") then
        should_proxy = true
    elseif url:match("gist%.githubusercontent%.com") then
        should_proxy = true
    elseif url:match("github%.com/.*/.*/releases/download/") then
        -- Apply proxy to release download URLs only
        should_proxy = true
    elseif url:match("github%.com/.*/.*/archive/") then
        -- Apply proxy to archive download URLs only
        should_proxy = true
    elseif url:match("github%.com") and not url:match("api%.github%.com") then
        -- Apply proxy to other GitHub pages (but not API)
        should_proxy = true
    end
    
    if should_proxy then
        -- URL encode the original URL for the query parameter
        local encoded_url = url:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        
        -- Construct proxy URL with query parameter
        local proxied_url = proxy .. "?q=" .. encoded_url
        
        log_openlistui_operation("PROXY_APPLIED", "Applied proxy to download URL: " .. proxied_url)
        return proxied_url
    end
    
    -- Note: We deliberately don't proxy api.github.com to avoid rate limiting issues
    return url
end

-- Cache management functions
function get_cache_key(url)
    return url:gsub("[^%w]", "_")
end

function is_cache_valid(timestamp)
    return (os.time() - timestamp) < cache_ttl
end

function get_cached_response(cache_key)
    local cache_entry = github_cache[cache_key]
    if cache_entry and is_cache_valid(cache_entry.timestamp) then
        log_openlistui_operation("CACHE_HIT", "Using cached response for: " .. cache_key)
        return cache_entry.data
    end
    return nil
end

function set_cached_response(cache_key, data)
    github_cache[cache_key] = {
        data = data,
        timestamp = os.time()
    }
    log_openlistui_operation("CACHE_SET", "Cached response for: " .. cache_key)
end

-- Get cache statistics for debugging
function get_cache_stats()
    local total_entries = 0
    local valid_entries = 0
    local current_time = os.time()
    
    for key, entry in pairs(github_cache) do
        total_entries = total_entries + 1
        if is_cache_valid(entry.timestamp) then
            valid_entries = valid_entries + 1
        end
    end
    
    return {
        total = total_entries,
        valid = valid_entries,
        expired = total_entries - valid_entries,
        ttl_seconds = cache_ttl
    }
end

-- Enhanced curl execution with caching and proxy support
function execute_curl_with_cache(url, cache_key, extra_params)
    -- For API calls, don't apply proxy to maintain rate limiting compatibility
    local use_proxy = not url:match("api%.github%.com")
    local final_url = use_proxy and apply_proxy_to_url(url) or url
    
    if not cache_key then
        cache_key = get_cache_key(url)
    end
    
    -- Check cache first
    local cached_result = get_cached_response(cache_key)
    if cached_result then
        return cached_result
    end
    
    -- Build curl command
    local cmd = 'curl -s --connect-timeout 10 --max-time 30'
    
    -- Add User-Agent header (required by GitHub API)
    cmd = cmd .. ' -H "User-Agent: luci-app-openlistui/1.0"'
    
    -- Add GitHub token authentication for API calls
    if url:match("api%.github%.com") then
        local github_token = get_github_token()
        if github_token then
            cmd = cmd .. ' -H "Authorization: token ' .. github_token .. '"'
            log_openlistui_operation("API_AUTH", "Using GitHub token for API authentication")
        else
            log_openlistui_operation("API_AUTH", "No GitHub token configured, using anonymous access")
        end
    end
    
    if extra_params then
        cmd = cmd .. ' ' .. extra_params
    end
    cmd = cmd .. ' "' .. final_url .. '" 2>/dev/null'
    
    if use_proxy and final_url ~= url then
        log_openlistui_operation("API_REQUEST", "Executing with proxy: " .. cmd:gsub("token [^ ]*", "token [REDACTED]"))
    else
        log_openlistui_operation("API_REQUEST", "Executing direct: " .. cmd:gsub("token [^ ]*", "token [REDACTED]"))
    end
    
    -- Execute command
    local result = util.trim(sys.exec(cmd))
    
    -- Cache the result if it's not empty and doesn't look like an error
    if result and result ~= "" and not result:match("^curl:") then
        set_cached_response(cache_key, result)
    end
    
    return result
end

-- Calculate process CPU usage from /proc filesystem (OpenWrt compatible)
-- Global variables for CPU calculation
local last_cpu_data = {}

get_process_cpu_usage = function(pid)
    if not pid or pid == "" then
        return nil
    end
    
    -- Read process stat file
    local proc_stat = util.trim(sys.exec("cat /proc/" .. pid .. "/stat 2>/dev/null"))
    if not proc_stat or proc_stat == "" then
        return nil
    end
    
    -- Parse process stat (fields 14 and 15 are utime and stime)
    local stat_fields = {}
    for field in proc_stat:gmatch("%S+") do
        table.insert(stat_fields, field)
    end
    
    if #stat_fields < 15 then
        return nil
    end
    
    local utime = tonumber(stat_fields[14]) or 0
    local stime = tonumber(stat_fields[15]) or 0
    local total_time = utime + stime
    
    -- Get current time
    local current_time = os.time()
    
    -- Check if we have previous data for this PID
    local prev_data = last_cpu_data[pid]
    if not prev_data then
        -- First measurement, store data and return 0
        last_cpu_data[pid] = {
            total_time = total_time,
            timestamp = current_time
        }
        return 0
    end
    
    -- Calculate time differences
    local time_diff = current_time - prev_data.timestamp
    local cpu_time_diff = total_time - prev_data.total_time
    
    -- Update stored data
    last_cpu_data[pid] = {
        total_time = total_time,
        timestamp = current_time
    }
    
    -- Avoid division by zero
    if time_diff <= 0 then
        return 0
    end
    
    -- Get system clock ticks per second
    local hz_output = util.trim(sys.exec("getconf CLK_TCK 2>/dev/null"))
    local hz = tonumber(hz_output) or 100
    
    -- Calculate CPU usage percentage
    local cpu_usage = (cpu_time_diff / hz / time_diff) * 100
    return math.min(math.max(cpu_usage, 0), 100) -- Cap between 0-100%
end

-- Safe JSON output function
function write_json_response(success, message, debug_info)
    -- Escape special characters in message
    local escaped_message = (message or ""):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
    local json_response = '{"success":' .. (success and "true" or "false") .. ',"message":"' .. escaped_message .. '"'
    
    if debug_info and debug_info ~= "" then
        local escaped_debug = debug_info:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
        json_response = json_response .. ',"debug":"' .. escaped_debug .. '"'
    end
    
    json_response = json_response .. '}'
    
    -- Log the JSON response for debugging
    log_openlistui_operation("JSON_RESPONSE", "Sending response: " .. json_response)
    
    http.prepare_content("application/json")
    http.write(json_response)
    http.close()
end

-- Map system architecture to LuCI IPK architecture naming
function map_arch_to_luci_ipk(arch)
    local arch_map = {
        -- System architecture mappings for LuCI IPK files
        ["linux-musl-amd64"] = "x86_64",
        ["linux-musl-arm64"] = "aarch64", 
        ["linux-musleabihf-armv7l"] = "armv7",
        ["linux-musleabihf-armv6"] = "arm",
        ["linux-musl-mips"] = "mips",
        ["linux-musl-mipsle"] = "mipsel",
        
        -- Common variations
        ["x86_64"] = "x86_64",
        ["amd64"] = "x86_64",
        ["arm64"] = "aarch64",
        ["aarch64"] = "aarch64",
        ["armv7l"] = "armv7",
        ["mips"] = "mips",
        ["mipsel"] = "mipsel"
    }
    
    local mapped = arch_map[arch]
    if mapped then
        log_openlistui_operation("LUCI_ARCH_MAP", "Mapped architecture for LuCI: " .. arch .. " -> " .. mapped)
        return mapped
    else
        log_openlistui_operation("LUCI_ARCH_MAP", "Unknown architecture for LuCI: " .. arch .. ", using fallback: x86_64")
        return "x86_64"  -- fallback
    end
end

-- Map system architecture to GitHub release architecture naming
function map_arch_to_github_release(arch)
    local arch_map = {
        -- System architecture mappings
        ["linux-musl-amd64"] = "linux-musl-amd64",
        ["linux-musl-arm64"] = "linux-musl-arm64", 
        ["linux-musleabihf-armv7l"] = "linux-musleabihf-armv7l",
        ["linux-musleabihf-armv6"] = "linux-musleabihf-armv6",
        ["linux-musl-mips"] = "linux-musl-mips",
        ["linux-musl-mipsle"] = "linux-musl-mipsle",
        
        -- Frontend architecture selections to GitHub release naming
        ["linux-386"] = "linux-musl-386",
        ["linux-amd64"] = "linux-musl-amd64",
        ["linux-amd64-v3"] = "linux-musl-amd64",  -- Use standard amd64 for v3
        ["linux-armv5"] = "linux-musleabihf-armv5",
        ["linux-armv6"] = "linux-musleabihf-armv6",
        ["linux-armv7"] = "linux-musleabihf-armv7l",
        ["linux-arm64"] = "linux-musl-arm64",
        ["linux-loong64"] = "linux-musl-loong64",
        ["linux-riscv64"] = "linux-musl-riscv64",
        ["linux-mips"] = "linux-musl-mips",
        ["linux-mips64"] = "linux-musl-mips64",
        ["linux-mips64le"] = "linux-musl-mips64le",
        ["linux-mipsle"] = "linux-musl-mipsle",
        
        -- Common variations
        ["x86_64"] = "linux-musl-amd64",
        ["amd64"] = "linux-musl-amd64",
        ["arm64"] = "linux-musl-arm64",
        ["aarch64"] = "linux-musl-arm64"
    }
    
    local mapped = arch_map[arch]
    if mapped then
        log_openlistui_operation("ARCH_MAP", "Mapped architecture: " .. arch .. " -> " .. mapped)
        return mapped
    else
        log_openlistui_operation("ARCH_MAP", "Unknown architecture: " .. arch .. ", using fallback: linux-musl-amd64")
        return "linux-musl-amd64"  -- fallback
    end
end

-- Simple JSON parser for basic needs
local json = {}
function json.parse(str)
    if not str or str == "" then
        return nil
    end
    
    -- Very basic JSON parsing - this is a simplified version
    -- In a real implementation, you'd want a more robust parser
    local function parse_value(s, pos)
        local char = s:sub(pos, pos)
        if char == '"' then
            -- String
            local end_pos = s:find('"', pos + 1)
            if end_pos then
                return s:sub(pos + 1, end_pos - 1), end_pos + 1
            end
        elseif char == '{' then
            -- Object
            local obj = {}
            pos = pos + 1
            while pos <= #s do
                local c = s:sub(pos, pos)
                if c == '}' then
                    return obj, pos + 1
                elseif c == '"' then
                    local key, new_pos = parse_value(s, pos)
                    pos = new_pos
                    -- Skip colon
                    local colon_pos = s:find(':', pos)
                    if colon_pos then
                        pos = colon_pos + 1
                    else
                        pos = pos + 1
                    end
                    -- Skip whitespace
                    while s:sub(pos, pos):match('%s') do pos = pos + 1 end
                    local value, new_pos2 = parse_value(s, pos)
                    obj[key] = value
                    pos = new_pos2
                    -- Skip comma
                    if s:sub(pos, pos) == ',' then pos = pos + 1 end
                else
                    pos = pos + 1
                end
            end
        elseif char:match('%d') or char == '-' then
            -- Number
            local num_end = pos
            while s:sub(num_end + 1, num_end + 1):match('[%d%.]') do
                num_end = num_end + 1
            end
            return tonumber(s:sub(pos, num_end)), num_end + 1
        elseif s:sub(pos, pos + 3) == 'true' then
            return true, pos + 4
        elseif s:sub(pos, pos + 4) == 'false' then
            return false, pos + 5
        end
        return nil, pos + 1
    end
    
    local result, _ = parse_value(str, 1)
    return result
end

-- JSON encoding function compatible with OpenWrt/LuCI
function json_encode(data)
    if type(data) == "table" then
        local items = {}
        local is_array = true
        local count = 0
        
        -- Check if it's an array or object
        for k, v in pairs(data) do
            count = count + 1
            if type(k) ~= "number" or k ~= count then
                is_array = false
                break
            end
        end
        
        if is_array and count > 0 then
            -- Array
            for i = 1, count do
                items[i] = json_encode(data[i])
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            -- Object
            for k, v in pairs(data) do
                table.insert(items, '"' .. tostring(k) .. '":' .. json_encode(v))
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    elseif type(data) == "string" then
        -- Escape special characters
        local escaped = data:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. escaped .. '"'
    elseif type(data) == "number" or type(data) == "boolean" then
        return tostring(data)
    elseif data == nil then
        return "null"
    else
        return '""'
    end
end

function index()
    -- 移除严格的配置文件检查，确保菜单总是显示
    -- if not nixio.fs.access("/etc/config/openlistui") then
    --     return
    -- end

    -- 在函数内部导入 i18n 模块并定义翻译函数
    local i18n = require "luci.i18n"
    local _ = i18n.translate
    
    local page = luci.dispatcher.entry({"admin", "services", "openlistui"}, luci.dispatcher.firstchild(), _("OpenList UI"), 60)
    page.dependent = false
    page.acl_depends = {"luci-app-openlistui"}
    
    -- Main pages
    luci.dispatcher.entry({"admin", "services", "openlistui", "overview"}, 
          luci.dispatcher.template("openlistui/overview"), _("Overview"), 1)

    luci.dispatcher.entry({"admin", "services", "openlistui", "updates"}, 
          luci.dispatcher.template("openlistui/updates"), _("Updates"), 2)

    luci.dispatcher.entry({"admin", "services", "openlistui", "settings"}, 
          luci.dispatcher.cbi("openlistui/settings"), _("Settings"), 3)

    luci.dispatcher.entry({"admin", "services", "openlistui", "logs"}, 
          luci.dispatcher.template("openlistui/logs"), _("Logs"), 4)

    -- API endpoints for service management
    luci.dispatcher.entry({"admin", "services", "openlistui", "status"}, 
          luci.dispatcher.call("action_status"), nil).leaf = true

    luci.dispatcher.entry({"admin", "services", "openlistui", "start"}, 
          luci.dispatcher.call("action_start"), nil).leaf = true

    luci.dispatcher.entry({"admin", "services", "openlistui", "stop"}, 
          luci.dispatcher.call("action_stop"), nil).leaf = true

    luci.dispatcher.entry({"admin", "services", "openlistui", "restart"}, 
          luci.dispatcher.call("action_restart"), nil).leaf = true

    -- Settings management endpoints
    luci.dispatcher.entry({"admin", "services", "openlistui", "settings_get"}, 
          luci.dispatcher.call("action_settings_get"), nil).leaf = true

    luci.dispatcher.entry({"admin", "services", "openlistui", "settings_save"}, 
          luci.dispatcher.call("action_settings_save"), nil).leaf = true

    luci.dispatcher.entry({"admin", "services", "openlistui", "generate_password"}, 
          luci.dispatcher.call("action_generate_password"), nil).leaf = true


    

    

    
    -- Log management endpoints  
    luci.dispatcher.entry({"admin", "services", "openlistui", "logs_get"}, 
          luci.dispatcher.call("action_logs_get"), nil).leaf = true
    
    luci.dispatcher.entry({"admin", "services", "openlistui", "logs_clear"}, 
          luci.dispatcher.call("action_logs_clear"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "log_config_get"}, 
          luci.dispatcher.call("action_log_config_get"), nil).leaf = true
          
    -- Remote configuration endpoints
    luci.dispatcher.entry({"admin", "services", "openlistui", "remote_list"}, 
          luci.dispatcher.call("action_remote_list"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "remote_create"}, 
          luci.dispatcher.call("action_remote_create"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "remote_delete"}, 
          luci.dispatcher.call("action_remote_delete"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "remote_test"}, 
          luci.dispatcher.call("action_remote_test"), nil).leaf = true
          
    -- System information endpoints
    luci.dispatcher.entry({"admin", "services", "openlistui", "system_info"}, 
          luci.dispatcher.call("action_system_info"), nil).leaf = true
          
    -- Update management endpoints (existing)
    luci.dispatcher.entry({"admin", "services", "openlistui", "check_updates"}, 
          luci.dispatcher.call("action_check_updates"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "download_update"}, 
          luci.dispatcher.call("action_download_update"), nil).leaf = true

    luci.dispatcher.entry({"admin", "services", "openlistui", "github_releases"}, 
          luci.dispatcher.call("action_github_releases"), nil).leaf = true
    
    -- New OpenClash-style update endpoints
    luci.dispatcher.entry({"admin", "services", "openlistui", "update_info"}, 
          luci.dispatcher.call("action_update_info"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "update"}, 
          luci.dispatcher.call("action_update"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "save_config"}, 
          luci.dispatcher.call("action_save_config"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "component_update"}, 
          luci.dispatcher.call("action_component_update"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "get_download_url"}, 
          luci.dispatcher.call("action_get_download_url"), nil).leaf = true
          
    -- Install OpenList endpoint
    luci.dispatcher.entry({"admin", "services", "openlistui", "install_openlist"}, 
          luci.dispatcher.call("action_install_openlist"), nil).leaf = true
          
    -- LuCI App update endpoints
    luci.dispatcher.entry({"admin", "services", "openlistui", "check_luci_updates"}, 
          luci.dispatcher.call("action_check_luci_updates"), nil).leaf = true
          
    luci.dispatcher.entry({"admin", "services", "openlistui", "download_luci_update"}, 
          luci.dispatcher.call("action_download_luci_update"), nil).leaf = true
          
    -- File management endpoints
    -- 以下功能暂未实现，已注释
    -- entry({"admin", "services", "openlistui", "file_list"}, 
    --       call("action_file_list"), nil).leaf = true
    --       
    -- entry({"admin", "services", "openlistui", "file_upload"}, 
    --       call("action_file_upload"), nil).leaf = true

    -- Download log endpoint (暂未实现)
    -- entry({"admin", "services", "openlistui", "download_log"}, 
    --       call("action_download_log"), nil).leaf = true
    --       
    -- Get download log endpoint (暂未实现)
    -- entry({"admin", "services", "openlistui", "get_download_log"}, 
    --       call("action_get_download_log"), nil).leaf = true
    --       
    -- Get install log endpoint (暂未实现)
    -- entry({"admin", "services", "openlistui", "get_install_log"}, 
    --       call("action_get_install_log"), nil).leaf = true
          
    -- Get kernel save path endpoint
    luci.dispatcher.entry({"admin", "services", "openlistui", "get_kernel_save_path"}, 
          luci.dispatcher.call("action_get_kernel_save_path"), nil).leaf = true
          
    -- Get version info endpoint (current + latest)
    luci.dispatcher.entry({"admin", "services", "openlistui", "get_version_info"}, 
          luci.dispatcher.call("action_get_version_info"), nil).leaf = true
          
    -- Simple test endpoint
    luci.dispatcher.entry({"admin", "services", "openlistui", "test"}, 
          luci.dispatcher.call("action_test"), nil).leaf = true
          
    -- GitHub token test endpoint
    luci.dispatcher.entry({"admin", "services", "openlistui", "test_github_token"}, 
          luci.dispatcher.call("action_test_github_token"), nil).leaf = true
          
    -- Cache status endpoint for debugging
    luci.dispatcher.entry({"admin", "services", "openlistui", "cache_status"}, 
          luci.dispatcher.call("action_cache_status"), nil).leaf = true
          
    -- Get download URLs endpoint
    luci.dispatcher.entry({"admin", "services", "openlistui", "get_download_urls"}, 
          luci.dispatcher.call("action_get_download_urls"), nil).leaf = true
end

-- Helper function to get process uptime
function get_process_uptime(pid)
    if not pid then
        log_openlistui_operation("UPTIME_DEBUG", "No PID provided")
        return "Unknown"
    end
    
    -- Try to get process start time from /proc/pid/stat
    local stat_data = util.trim(sys.exec("cat /proc/" .. pid .. "/stat 2>/dev/null"))
    if stat_data and stat_data ~= "" then
        local stat_fields = {}
        for field in stat_data:gmatch("%S+") do
            table.insert(stat_fields, field)
        end
        
        log_openlistui_operation("UPTIME_DEBUG", "Stat fields count: " .. #stat_fields)
        if #stat_fields >= 22 then
            local starttime = tonumber(stat_fields[22]) or 0
            log_openlistui_operation("UPTIME_DEBUG", "Process starttime: " .. starttime)
            local uptime_data = util.trim(sys.exec("cat /proc/uptime 2>/dev/null"))
            if uptime_data and uptime_data ~= "" then
                local system_uptime = tonumber(uptime_data:match("^([%d%.]+)")) or 0
                local hz_output = util.trim(sys.exec("getconf CLK_TCK 2>/dev/null"))
                local hz = tonumber(hz_output) or 100
                local process_uptime = system_uptime - (starttime / hz)
                log_openlistui_operation("UPTIME_DEBUG", string.format("system_uptime=%.2f, hz=%d, process_uptime=%.2f", system_uptime, hz, process_uptime))
                
                if process_uptime > 0 then
                    local days = math.floor(process_uptime / 86400)
                    local hours = math.floor((process_uptime % 86400) / 3600)
                    local minutes = math.floor((process_uptime % 3600) / 60)
                    local seconds = math.floor(process_uptime % 60)
                    
                    if days > 0 then
                        return string.format("%dd %02d:%02d:%02d", days, hours, minutes, seconds)
                    elseif hours > 0 then
                        return string.format("%02d:%02d:%02d", hours, minutes, seconds)
                    else
                        return string.format("%02d:%02d", minutes, seconds)
                    end
                end
            end
        end
    end
    
    -- Fallback: OpenWrt/busybox compatible ps command
    local ps_cmd = "ps | grep -w " .. pid .. " | awk '{print $4}' 2>/dev/null"
    local uptime = util.trim(sys.exec(ps_cmd))
    log_openlistui_operation("UPTIME_DEBUG", "PS command result: '" .. (uptime or "nil") .. "'")
    if uptime and uptime ~= "" and uptime ~= "0" then
        log_openlistui_operation("UPTIME_DEBUG", "Using PS fallback result: " .. uptime)
        return uptime
    end
    
    log_openlistui_operation("UPTIME_DEBUG", "All methods failed, returning Unknown")
    return "Unknown"
end
-- Service status check
function action_status()
    -- Log status check
    log_openlistui_operation("STATUS_CHECK", "Checking OpenList service status")
    
    local result = {}
    local openlist_running = false
    local pid = nil
    
    -- Get version and installation info first
    result.version = get_openlist_version()
    result.install_path = get_openlist_install_path()
    result.binary_exists = fs.access(get_openlist_binary_path())
    
    -- Always check for running processes, regardless of binary_exists status
    -- This handles cases where the service is running but UCI config is wrong
    
    -- Priority 1: Check system paths first (most common installation)
    local system_paths = {"/usr/bin/openlist", "/usr/local/bin/openlist", "/opt/bin/openlist", "/tmp/openlist"}
    
    for _, sys_path in ipairs(system_paths) do
        local pid_output = util.trim(sys.exec("pgrep -f '" .. sys_path .. "' 2>/dev/null | head -1"))
        if pid_output and pid_output ~= "" then
            local check_pid = tonumber(pid_output)
            if check_pid then
                local proc_status = util.trim(sys.exec("cat /proc/" .. check_pid .. "/status 2>/dev/null | grep '^State:' | awk '{print $2}'"))
                if proc_status == "R" or proc_status == "S" or proc_status == "D" then
                    local proc_exe = util.trim(sys.exec("readlink -f /proc/" .. check_pid .. "/exe 2>/dev/null"))
                    if proc_exe == sys_path then
                        openlist_running = true
                        pid = check_pid
                        log_openlistui_operation("STATUS_CHECK_SYSTEM", "Found OpenList at system path: " .. sys_path .. " PID: " .. check_pid)
                        break
                    end
                end
            end
        end
    end
    
    -- Priority 2: Check configured path if not found in system paths
    if not openlist_running then
        local binary_path = get_openlist_binary_path()
        local pid_output = util.trim(sys.exec("pgrep -f '" .. binary_path .. "' 2>/dev/null | head -1"))
        
        if pid_output and pid_output ~= "" then
            local check_pid = tonumber(pid_output)
            if check_pid then
                local proc_status = util.trim(sys.exec("cat /proc/" .. check_pid .. "/status 2>/dev/null | grep '^State:' | awk '{print $2}'"))
                if proc_status == "R" or proc_status == "S" or proc_status == "D" then
                    local proc_exe = util.trim(sys.exec("readlink -f /proc/" .. check_pid .. "/exe 2>/dev/null"))
                    if proc_exe == binary_path then
                        openlist_running = true
                        pid = check_pid
                        log_openlistui_operation("STATUS_CHECK_CONFIG", "Found OpenList at configured path: " .. binary_path .. " PID: " .. check_pid)
                    else
                        -- Fallback: check command line if exe link fails
                        local cmdline = util.trim(sys.exec("cat /proc/" .. check_pid .. "/cmdline 2>/dev/null | tr '\0' ' '"))
                        if cmdline and cmdline:find(binary_path, 1, true) then
                            openlist_running = true
                            pid = check_pid
                            log_openlistui_operation("STATUS_CHECK_CMDLINE", "Used cmdline fallback for PID " .. check_pid)
                        end
                    end
                end
            end
        end
    end
    
    -- Priority 3: Generic fallback check for any openlist process (more flexible)
    if not openlist_running then
        local fallback_pid = util.trim(sys.exec("pgrep -f 'openlist' 2>/dev/null | head -1"))
        if fallback_pid and fallback_pid ~= "" then
            local check_pid = tonumber(fallback_pid)
            if check_pid then
                local proc_status = util.trim(sys.exec("cat /proc/" .. check_pid .. "/status 2>/dev/null | grep '^State:' | awk '{print $2}'"))
                if proc_status == "R" or proc_status == "S" or proc_status == "D" then
                    -- More flexible check - accept any openlist process
                    local proc_exe = util.trim(sys.exec("readlink -f /proc/" .. check_pid .. "/exe 2>/dev/null"))
                    local cmdline = util.trim(sys.exec("cat /proc/" .. check_pid .. "/cmdline 2>/dev/null | tr '\0' ' '"))
                    
                    -- Check if it's really an openlist process
                    if (proc_exe and proc_exe:find("openlist")) or (cmdline and cmdline:find("openlist")) then
                        openlist_running = true
                        pid = check_pid
                        log_openlistui_operation("STATUS_CHECK_GENERIC", "Found OpenList via generic search - exe: " .. (proc_exe or "unknown") .. ", cmdline: " .. (cmdline or "unknown") .. ", PID: " .. check_pid)
                    end
                end
            end
        end
    end
    
    -- Priority 4: Final fallback - check by process name only
    if not openlist_running then
        local name_pid = util.trim(sys.exec("pgrep openlist 2>/dev/null | head -1"))
        if name_pid and name_pid ~= "" then
            local check_pid = tonumber(name_pid)
            if check_pid then
                local proc_status = util.trim(sys.exec("cat /proc/" .. check_pid .. "/status 2>/dev/null | grep '^State:' | awk '{print $2}'"))
                if proc_status == "R" or proc_status == "S" or proc_status == "D" then
                    openlist_running = true
                    pid = check_pid
                    log_openlistui_operation("STATUS_CHECK_NAME", "Found OpenList by process name, PID: " .. check_pid)
                end
            end
        end
    end
    
    result.running = openlist_running
    
    if openlist_running and pid then
        result.pid = pid
        result.port = uci:get("openlistui", "main", "port") or "5244"
        -- Get process uptime using improved method
        result.uptime = get_process_uptime(pid)
        
        -- Get memory usage in KB from /proc/pid/status (more reliable on OpenWrt)
        local memory_kb = util.trim(sys.exec("cat /proc/" .. pid .. "/status 2>/dev/null | grep VmRSS | awk '{print $2}'"))
        if memory_kb and memory_kb ~= "" and tonumber(memory_kb) then
            result.memory = memory_kb
            log_openlistui_operation("MONITOR_MEMORY", "Got memory from /proc: " .. memory_kb .. " KB")
        else
            -- Fallback to ps if /proc is not available
            local ps_memory = util.trim(sys.exec("ps | grep -w " .. pid .. " | awk '{print $5}' 2>/dev/null"))
            result.memory = ps_memory
            log_openlistui_operation("MONITOR_MEMORY", "Fallback to ps memory: " .. (ps_memory or "N/A"))
        end
        
        -- Get CPU usage from /proc/stat and /proc/pid/stat (more accurate)
        local cpu_usage = get_process_cpu_usage(pid)
        if cpu_usage and cpu_usage >= 0 then
            result.cpu = string.format("%.1f", cpu_usage)
            log_openlistui_operation("MONITOR_CPU", "Got CPU from /proc: " .. result.cpu .. "%")
        else
            -- Fallback: use top command for CPU (busybox compatible)
            local top_cpu = util.trim(sys.exec("top -bn1 -p " .. pid .. " 2>/dev/null | tail -1 | awk '{print $7}' | sed 's/%//'"))
            if top_cpu and top_cpu ~= "" and tonumber(top_cpu) then
                result.cpu = top_cpu
                log_openlistui_operation("MONITOR_CPU", "Fallback to top CPU: " .. top_cpu .. "%")
            else
                -- Final fallback: simple ps approach
                result.cpu = "0.0"
                log_openlistui_operation("MONITOR_CPU", "CPU monitoring failed, defaulting to 0.0%")
            end
        end
    end
    
    -- Check service status
    local service_enabled = uci:get("openlistui", "main", "enabled") == "1"
    result.enabled = service_enabled
    
    -- Add binary size information if exists
    if result.binary_exists then
        local stat = fs.stat(get_openlist_binary_path())
        if stat and stat.size then
            if stat.size > 1024*1024 then
                result.binary_size = string.format("%.1f MB", stat.size / (1024*1024))
            elseif stat.size > 1024 then
                result.binary_size = string.format("%.1f KB", stat.size / 1024)
            else
                result.binary_size = stat.size .. " bytes"
            end
        end
    end
    
    -- Log key status fields for debugging
    log_openlistui_operation("STATUS_RESPONSE", "Status result - running: " .. tostring(result.running) .. ", version: " .. tostring(result.version) .. ", pid: " .. tostring(result.pid))
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Start OpenList service
function action_start()
    local result = {}
    
    log_openlistui_operation("SERVICE_START", "Attempting to start OpenList service")
    
    -- Check if service is enabled, if not enable it automatically when starting via LuCI
    local enabled = uci:get("openlistui", "main", "enabled") or "0"
    if enabled == "0" then
        log_openlistui_operation("SERVICE_START", "Service is disabled, enabling it automatically")
        uci:set("openlistui", "main", "enabled", "1")
        uci:commit("openlistui")
    end
    
    -- Check if binary exists before trying to start
    local binary_path = get_openlist_binary_path()
    log_openlistui_operation("SERVICE_START_DEBUG", "Binary path: " .. binary_path)
    
    if not fs.access(binary_path) then
        result.success = false
        result.message = "OpenList binary not found at: " .. binary_path .. ". Please install OpenList first."
        log_openlistui_operation("SERVICE_START_FAILED", "Binary not found at " .. binary_path)
        write_json_response(false, result.message)
        return
    end
    
    log_openlistui_operation("SERVICE_START_DEBUG", "Binary found, calling init.d script")
    local ret = sys.call("/etc/init.d/openlistui start 2>&1")
    log_openlistui_operation("SERVICE_START_DEBUG", "Init.d script returned: " .. ret)
    
    if ret == 0 then
        -- Wait a moment for service to start
        log_openlistui_operation("SERVICE_START_DEBUG", "Init.d successful, waiting 2 seconds...")
        sys.exec("sleep 2")
        
        -- Check if our specific binary is running
        local status_check = sys.call("pgrep -f '" .. binary_path .. "' >/dev/null")
        log_openlistui_operation("SERVICE_START_DEBUG", "Process check for specific binary returned: " .. status_check)
        
        if status_check ~= 0 then
            -- Fallback check for any openlist process
            status_check = sys.call("pgrep -f openlist >/dev/null")
            log_openlistui_operation("SERVICE_START_DEBUG", "Process check for any openlist returned: " .. status_check)
        end
        
        -- If process not found, check logs for errors
        if status_check ~= 0 then
            -- Check OpenList application log
            local openlist_log_path = get_openlist_log_path()
            local log_content = sys.exec("tail -20 '" .. openlist_log_path .. "' 2>/dev/null || echo 'No OpenList log file'")
            log_openlistui_operation("SERVICE_START_ERROR", "Process not running, OpenList log: " .. log_content)
            
            -- Check system log for procd errors
            local procd_log = sys.exec("logread | grep -E '(openlistui|procd.*openlist)' | tail -10 2>/dev/null || echo 'No procd logs'")
            log_openlistui_operation("SERVICE_START_ERROR", "System logs: " .. procd_log)
            
            -- Check if binary is corrupted or missing dependencies
            local binary_check = sys.exec("ldd '" .. binary_path .. "' 2>&1 | head -10 || file '" .. binary_path .. "' 2>&1")
            log_openlistui_operation("SERVICE_START_ERROR", "Binary check: " .. binary_check)
            
            -- Check config file
            local config_check = sys.exec("ls -la /etc/openlistui/data/config.json 2>&1 && head -5 /etc/openlistui/data/config.json 2>&1")
            log_openlistui_operation("SERVICE_START_ERROR", "Config check: " .. config_check)
        end
        
        result.success = (status_check == 0)
    else
        result.success = false
        log_openlistui_operation("SERVICE_START_ERROR", "Init.d script failed with code: " .. ret)
    end
    
    result.message = result.success and "OpenList service started successfully" or "Failed to start OpenList service"
    log_openlistui_operation("SERVICE_START_" .. (result.success and "SUCCESS" or "FAILED"), result.message)
    
    -- Add debug info to response
    local debug_info = nil
    if not result.success then
        debug_info = "Binary: " .. binary_path .. ", Init.d result: " .. ret
    end
    
    write_json_response(result.success, result.message, debug_info)
end

-- Stop OpenList service
function action_stop()
    local result = {}
    
    log_openlistui_operation("SERVICE_STOP", "Attempting to stop OpenList service")
    
    local ret = sys.call("/etc/init.d/openlistui stop 2>/dev/null")
    
    if ret == 0 then
        -- Force kill if still running
        sys.exec("sleep 1")
        sys.call("killall openlist 2>/dev/null || true")
        result.success = true
    else
        result.success = false
    end
    
    result.message = result.success and "OpenList service stopped successfully" or "Failed to stop OpenList service"
    log_openlistui_operation("SERVICE_STOP_" .. (result.success and "SUCCESS" or "FAILED"), result.message)
    
    write_json_response(result.success, result.message)
end

-- Restart OpenList service
function action_restart()
    local result = {}
    
    log_openlistui_operation("SERVICE_RESTART", "Attempting to restart OpenList service")
    
    local ret = sys.call("/etc/init.d/openlistui restart 2>/dev/null")
    
    if ret == 0 then
        sys.exec("sleep 3")
        local status_check = sys.call("pgrep -f openlist >/dev/null")
        result.success = (status_check == 0)
    else
        result.success = false
    end
    
    result.message = result.success and "OpenList service restarted successfully" or "Failed to restart OpenList service"
    log_openlistui_operation("SERVICE_RESTART_" .. (result.success and "SUCCESS" or "FAILED"), result.message)
    
    write_json_response(result.success, result.message)
end







-- Get OpenList log path from config.json
function get_openlist_log_path()
    local uci = require "luci.model.uci".cursor()
    local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
    local config_file = data_dir .. "/data/config.json"
    local default_log_path = data_dir .. "/data/log/log.log"
    
    if fs.access(config_file) then
        local content = fs.readfile(config_file)
        if content then
            -- Extract log path from config.json
            local log_path = content:match('"name":%s*"([^"]+)"')
            if log_path and log_path ~= "" then
                return log_path
            end
        end
    end
    
    return default_log_path
end

-- Get logs
function action_logs_get()
    local source = http.formvalue("source") or "all"
    local lines = tonumber(http.formvalue("lines")) or 100
    local result = {}
    local logs = {}
    

    
    if source == "all" or source == "openlist" then
        -- Get actual log path from config.json
        local openlist_log_path = get_openlist_log_path()
        local openlist_logs = sys.exec(string.format("tail -n %d '%s' 2>/dev/null | sed 's/^/[OpenList] /'", lines, openlist_log_path))
        if openlist_logs and openlist_logs ~= "" then
            for line in openlist_logs:gmatch("[^\r\n]+") do
                table.insert(logs, line)
            end
        end
    end
    

    
    if source == "all" or source == "openlistui" then
        local enable_logging = uci:get("openlistui", "main", "enable_logging") or "1"
        
        if enable_logging == "1" then
            -- Get OpenListUI logs from configured log file
            local log_file = uci:get("openlistui", "main", "log_file") or "/var/log/openlistui.log"
            local openlistui_file_logs = sys.exec(string.format("tail -n %d '%s' 2>/dev/null | sed 's/^/[OpenListUI] /'", lines, log_file))
            if openlistui_file_logs and openlistui_file_logs ~= "" then
                for line in openlistui_file_logs:gmatch("[^\r\n]+") do
                    table.insert(logs, line)
                end
            end
        else
            -- Fallback to system log if file logging is disabled
            local openlistui_logs = sys.exec(string.format("logread | grep 'openlistui' | tail -n %d | sed 's/^/[OpenListUI] /'", lines))
            if openlistui_logs and openlistui_logs ~= "" then
                for line in openlistui_logs:gmatch("[^\r\n]+") do
                    table.insert(logs, line)
                end
            end
        end
    end
    
    -- System logs removed as requested
    
    -- Sort logs by timestamp if possible
    table.sort(logs, function(a, b)
        -- Extract timestamp from log lines
        local function extract_timestamp(line)
            -- Try to match common timestamp formats
            local patterns = {
                "(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)",  -- YYYY-MM-DD HH:MM:SS
                "(%w%w%w %d%d %d%d:%d%d:%d%d)",           -- Mon DD HH:MM:SS
                "(%d%d%d%d/%d%d/%d%d %d%d:%d%d:%d%d)"      -- YYYY/MM/DD HH:MM:SS
            }
            
            for _, pattern in ipairs(patterns) do
                local timestamp = line:match(pattern)
                if timestamp then
                    return timestamp
                end
            end
            return line  -- fallback to original line for sorting
        end
        
        local ts_a = extract_timestamp(a)
        local ts_b = extract_timestamp(b)
        return ts_a < ts_b
    end)
    
    result.logs = logs
    result.count = #logs
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Clear logs
function action_logs_clear()
    local source = http.formvalue("source") or "all"
    local result = {}
    
    if source == "all" or source == "openlist" then
        -- Get actual log path from config.json and clear it
        local openlist_log_path = get_openlist_log_path()
        sys.call(string.format("echo '' > '%s'", openlist_log_path))
    end
    

    
    if source == "all" or source == "openlistui" then
        local enable_logging = uci:get("openlistui", "main", "enable_logging") or "1"
        
        if enable_logging == "1" then
            -- Clear configured OpenListUI log file
            local log_file = uci:get("openlistui", "main", "log_file") or "/var/log/openlistui.log"
            sys.call(string.format("echo '' > '%s' 2>/dev/null", log_file))
            -- Log this action to the same file
            local timestamp = os.date("%Y-%m-%d %H:%M:%S")
            sys.exec(string.format("echo '[%s] [LOG_CLEAR] OpenListUI logs cleared by user' >> '%s' 2>/dev/null", timestamp, log_file))
        else
            -- Log this action to system log if file logging is disabled
            log_openlistui_operation("LOG_CLEAR", "OpenListUI logs cleared by user")
        end
    end
    
    -- System logs clearing removed as requested
    
    result.success = true
    result.message = "Logs cleared successfully"
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Get log configuration
function action_log_config_get()
    local result = {}
    local uci = require "luci.model.uci".cursor()
    local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
    local config_file = data_dir .. "/data/config.json"
    
    result.log_path = data_dir .. "/data/log/log.log"  -- default
    result.max_size = 50
    result.max_backups = 30
    result.max_age = 28
    result.compress = false
    result.enable = true
    
    if fs.access(config_file) then
        local content = fs.readfile(config_file)
        if content then
            -- Extract log configuration from config.json
            local log_section = content:match('"log":%s*{([^}]+)}')
            if log_section then
                local log_path = log_section:match('"name":%s*"([^"]+)"')
                local max_size = log_section:match('"max_size":%s*(%d+)')
                local max_backups = log_section:match('"max_backups":%s*(%d+)')
                local max_age = log_section:match('"max_age":%s*(%d+)')
                local compress = log_section:match('"compress":%s*(true|false)')
                local enable = log_section:match('"enable":%s*(true|false)')
                
                if log_path then result.log_path = log_path end
                if max_size then result.max_size = tonumber(max_size) end
                if max_backups then result.max_backups = tonumber(max_backups) end
                if max_age then result.max_age = tonumber(max_age) end
                if compress then result.compress = (compress == "true") end
                if enable then result.enable = (enable == "true") end
            end
        end
    end
    
    -- Get log file size if it exists
    if fs.access(result.log_path) then
        local stat = fs.stat(result.log_path)
        if stat then
            result.current_size = math.floor(stat.size / 1024)  -- KB
        end
    else
        result.current_size = 0
    end
    
    result.success = true
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- List remote configurations
function action_remote_list()
    local result = {}
    local remotes = {}
    
    uci:foreach("openlistui", "remote", function(s)
        local remote = {
            name = s[".name"],
            type = s.type or "webdav",
            url = s.url or "",
            username = s.username or "",
            vendor = s.vendor or "",
            enabled = s.enabled ~= "0"
        }
        table.insert(remotes, remote)
    end)
    
    result.remotes = remotes
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Create remote configuration
function action_remote_create()
    local req = http.content()
    local data = json.parse(req)
    local result = {}
    
    if not data or not data.name or not data.type then
        result.success = false
        result.message = "Missing required parameters: name, type"
    else
        -- Check if remote name already exists
        local exists = false
        uci:foreach("openlistui", "remote", function(s)
            if s[".name"] == data.name then
                exists = true
                return false
            end
        end)
        
        if exists then
            result.success = false
            result.message = "Remote with this name already exists"
        else
            -- Create UCI section
            local section = uci:add("openlistui", "remote")
            uci:set("openlistui", section, "type", data.type)
            uci:set("openlistui", section, "url", data.url or "")
            uci:set("openlistui", section, "username", data.username or "")
            uci:set("openlistui", section, "password", data.password or "")
            uci:set("openlistui", section, "vendor", data.vendor or "")
            uci:set("openlistui", section, "enabled", data.enabled and "1" or "0")
            
            uci:commit("openlistui")
            
            -- RClone functionality removed
            
            result.success = true
            result.message = "Remote configuration created successfully"
        end
    end
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Delete remote configuration
function action_remote_delete()
    local req = http.content()
    local data = json.parse(req)
    local result = {}
    
    if not data or not data.name then
        result.success = false
        result.message = "Missing remote name"
    else
        -- Find and delete UCI section
        local deleted = false
        uci:foreach("openlistui", "remote", function(s)
            if s[".name"] == data.name then
                uci:delete("openlistui", s[".name"])
                deleted = true
                return false
            end
        end)
        
        if deleted then
            uci:commit("openlistui")
            
            -- RClone functionality removed
            
            result.success = true
            result.message = "Remote configuration deleted successfully"
        else
            result.success = false
            result.message = "Remote configuration not found"
        end
    end
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Test remote connection
function action_remote_test()
    local req = http.content()
    local data = json.parse(req)
    local result = {}
    
    if not data or not data.name then
        result.success = false
        result.message = "Missing remote name"
    else
        -- RClone functionality removed
        result.success = false
        result.message = "RClone functionality has been removed"
        result.output = "RClone is no longer supported"
    end
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Get system information
function action_system_info()
    local result = {}
    
    result.system = {
        hostname = util.trim(sys.exec("hostname")),
        uptime = util.trim(sys.exec("uptime | awk '{print $3,$4}' | sed 's/,//'")),
        load_avg = util.trim(sys.exec("uptime | awk -F'load average:' '{print $2}'")),
        memory = {
            total = util.trim(sys.exec("free -m | awk '/^Mem:/ {print $2}'")),
            used = util.trim(sys.exec("free -m | awk '/^Mem:/ {print $3}'")),
            free = util.trim(sys.exec("free -m | awk '/^Mem:/ {print $4}'")),
            available = util.trim(sys.exec("free -m | awk '/^Mem:/ {print $7}'"))
        },
        disk = {
            total = util.trim(sys.exec("df -h / | awk 'NR==2 {print $2}'")),
            used = util.trim(sys.exec("df -h / | awk 'NR==2 {print $3}'")),
            available = util.trim(sys.exec("df -h / | awk 'NR==2 {print $4}'")),
            usage = util.trim(sys.exec("df -h / | awk 'NR==2 {print $5}'"))
        },
        kernel = util.trim(sys.exec("uname -r")),
        architecture = util.trim(sys.exec("uname -m")),
        openwrt_version = util.trim(sys.exec("cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION | cut -d'=' -f2 | tr -d '\"'")),
        openlist_version = get_openlist_version()
    }
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Check for updates
function action_check_updates()
    local result = {}
    
    log_openlistui_operation("UPDATE_CHECK", "Checking for updates")
    
    -- Check OpenList updates
    local openlist_latest = get_latest_openlist_version()
    local openlist_current = get_openlist_version()
    
    -- Improved update availability logic
    local openlist_update_available = false
    
    -- Only show update available if we have valid versions
    if openlist_current ~= "Not installed" and openlist_current ~= "unknown" and openlist_current ~= "Network error" and
       openlist_latest ~= "unknown" and openlist_latest ~= "Network error" and openlist_latest ~= "" and
       openlist_current ~= openlist_latest then
        openlist_update_available = true
    end
    
    result.updates = {
        openlist = {
            current = openlist_current,
            latest = openlist_latest,
            update_available = openlist_update_available
        }
    }
    
    log_openlistui_operation("UPDATE_CHECK_RESULT", 
        string.format("OpenList: %s -> %s (update: %s)",
            openlist_current, openlist_latest, tostring(openlist_update_available)))
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Download and install updates
function action_download_update()
    local component = http.formvalue("component") or "openlist"
    local result = {}
    
    log_openlistui_operation("UPDATE_DOWNLOAD", "Starting update download for " .. component)
    
    if component == "openlist" then
        result.success = update_openlist()
        result.message = result.success and "OpenList updated successfully" or "Failed to update OpenList"
    else
        result.success = false
        result.message = "Unknown component: " .. component
    end
    
    log_openlistui_operation("UPDATE_DOWNLOAD_" .. (result.success and "SUCCESS" or "FAILED"), result.message)
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Install specific OpenList version
function action_install_openlist()
    local version = http.formvalue("version") or get_latest_openlist_version()
    local use_lite = http.formvalue("lite") == "true"
    local result = {}
    
    -- Resolve "latest" to actual version number for consistent logging
    if version == "latest" or version == "" then
        version = get_latest_openlist_version()
    end
    
    log_openlistui_operation("INSTALL_START", "Starting OpenList installation - version: " .. version .. (use_lite and " (Lite)" or ""))
    
    -- Log the installation attempt
    local suffix = use_lite and "-lite" or ""
    local kernel_save_path = get_kernel_save_path()
    local log_file = kernel_save_path .. "/openlist-install-" .. version .. suffix .. ".log"
    sys.exec(string.format("echo '[%s] Installation started for version %s%s' > %s", 
        os.date("%Y-%m-%d %H:%M:%S"), version, use_lite and " (Lite)" or "", log_file))
    
    if version == "unknown" or version == "Network error" then
        result.success = false
        result.message = "Unable to determine version to install - check network connection"
        log_openlistui_operation("INSTALL_FAILED", "Version determination failed: " .. version)
        sys.exec(string.format("echo '[ERROR] Unable to determine version: %s' >> %s", version, log_file))
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    -- Check architecture first
    local arch = get_system_arch()
    if not arch then
        result.success = false
        result.message = "Unsupported system architecture - cannot install OpenList"
        log_openlistui_operation("INSTALL_FAILED", "Architecture detection failed")
        sys.exec(string.format("echo '[ERROR] Architecture detection failed' >> %s", log_file))
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    log_openlistui_operation("INSTALL_ARCH_DETECTED", "Architecture: " .. arch)
    sys.exec(string.format("echo '[%s] Architecture detected: %s' >> %s", 
        os.date("%Y-%m-%d %H:%M:%S"), arch, log_file))
    
    -- Download and install
    log_openlistui_operation("INSTALL_DOWNLOAD_START", "Starting download for version " .. version)
    sys.exec(string.format("echo '[%s] Starting download...' >> %s", 
        os.date("%Y-%m-%d %H:%M:%S"), log_file))
    local success, binary_path = download_openlist(version, use_lite)
    if not success then
        result.success = false
        result.message = binary_path  -- Error message is in binary_path when success is false
        log_openlistui_operation("INSTALL_DOWNLOAD_FAILED", binary_path)
        sys.exec(string.format("echo '[ERROR] Download failed: %s' >> %s", binary_path, log_file))
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    log_openlistui_operation("INSTALL_DOWNLOAD_SUCCESS", "Download completed, starting installation")
    sys.exec(string.format("echo '[%s] Download completed, starting installation...' >> %s", 
        os.date("%Y-%m-%d %H:%M:%S"), log_file))
    local install_success, message = install_openlist(binary_path)
    
    -- Clean up temporary files
    local kernel_save_path = get_kernel_save_path()
    sys.exec("rm -rf " .. kernel_save_path .. "/openlist-" .. version .. "*")
    
    sys.exec(string.format("echo '[%s] Installation %s: %s' >> %s", 
        os.date("%Y-%m-%d %H:%M:%S"), install_success and "completed" or "failed", 
        message or "unknown", log_file))
    
    result.success = install_success
    result.message = install_success and ("OpenList " .. version .. (use_lite and " (Lite)" or "") .. " installed successfully") or message
    result.version = install_success and get_openlist_version() or nil
    
    -- Log final result
    log_openlistui_operation("INSTALL_" .. (install_success and "SUCCESS" or "FAILED"), 
        result.message .. (result.version and " (version: " .. result.version .. ")" or ""))
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Get GitHub releases list
function action_github_releases()
    local result = {}
    local include_prerelease = http.formvalue("include_prerelease") == "true"
    
    -- Get system architecture
    local system_arch = get_system_arch()
    if not system_arch then
        result.success = false
        result.message = "Unsupported system architecture - cannot detect compatible OpenList release"
        result.releases = {}
        result.current_version = get_openlist_version()
        result.system_arch = nil
        result.arch_display = "Unknown"
        
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    -- Get releases from GitHub API
    local releases = get_github_releases(include_prerelease)
    
    result.success = #releases > 0
    result.releases = releases
    result.current_version = get_openlist_version()
    result.system_arch = system_arch
    result.arch_display = get_arch_display_name(system_arch)
    
    if not result.success then
        result.message = "Failed to fetch releases from GitHub"
    end
    
    http.prepare_content("application/json")
    http.write_json(result)
end

function get_github_releases(include_prerelease)
    local releases = {}
    
    -- Try to get releases via API first with proxy and caching
    local url = "https://api.github.com/repos/OpenListTeam/OpenList/releases"
    local headers = '-H "Accept: application/vnd.github.v3+json"'
    local cache_key = "openlist_releases_" .. (include_prerelease and "all" or "stable")
    local json_data = execute_curl_with_cache(url, cache_key, headers)
    
    if json_data and json_data ~= "" then
        -- Parse JSON releases manually (simple parser)
        for block in json_data:gmatch('{[^{}]*"tag_name"[^{}]*}') do
            local tag_name = block:match('"tag_name":%s*"([^"]*)"')
            local name = block:match('"name":%s*"([^"]*)"') or tag_name
            local published_at = block:match('"published_at":%s*"([^"]*)"')
            local prerelease = block:match('"prerelease":%s*([^,}]*)')
            local draft = block:match('"draft":%s*([^,}]*)')
            
            if tag_name and published_at and draft ~= "true" then
                local is_prerelease = (prerelease == "true")
                
                -- Skip pre-releases if not requested
                if include_prerelease or not is_prerelease then
                    table.insert(releases, {
                        tag_name = tag_name,
                        name = name,
                        published_at = published_at,
                        prerelease = is_prerelease,
                        download_url = get_openlist_download_url(tag_name, false),  -- Full version
                        download_url_lite = get_openlist_download_url(tag_name, true)  -- Lite version
                    })
                end
            end
        end
    end
    
    -- Fallback: scrape from HTML if API fails (use proxy for web page access)
    if #releases == 0 then
        local html_url = "https://github.com/OpenListTeam/OpenList/releases"
        local proxied_html_url = apply_proxy_to_url(html_url)
        local html_cmd = 'curl -s "' .. proxied_html_url .. '"'
        local html_data = sys.exec(html_cmd)
        
        log_openlistui_operation("VERSION_SCRAPE", "Fallback to HTML scraping with proxy: " .. (proxied_html_url ~= html_url and "enabled" or "not applied"))
        
        if html_data then
            for tag in html_data:gmatch('/OpenListTeam/OpenList/releases/tag/([^"]*)"') do
                if tag and tag ~= "" then
                    table.insert(releases, {
                        tag_name = tag,
                        name = tag,
                        published_at = "Unknown",
                        prerelease = false,
                        download_url = get_openlist_download_url(tag, false),
                        download_url_lite = get_openlist_download_url(tag, true)
                    })
                    
                    -- Limit to 20 releases from HTML scraping
                    if #releases >= 20 then break end
                end
            end
        end
    end
    
    return releases
end

function get_arch_display_name(arch)
    if not arch then
        return "Unknown (Detection Failed)"
    end
    local arch_names = {
        ["amd64"] = "x86_64 (64-bit)",
        ["arm64"] = "ARM64 (aarch64)",
        ["mips"] = "MIPS (Big Endian)",
        ["mipsle"] = "MIPS (Little Endian)",
        ["mips64"] = "MIPS64 (Big Endian)",
        ["mips64le"] = "MIPS64 (Little Endian)",
        ["loong64"] = "LoongArch64",
        ["ppc64le"] = "PowerPC64 (Little Endian)",
        ["s390x"] = "IBM System z"
    }
    return arch_names[arch] or (arch .. " (Unknown)")
end

-- Helper functions
-- RClone functionality removed

-- RClone functionality removed

function get_openlist_install_path()
    return "/usr/share/openlistui"
end

function get_openlist_binary_path()
    -- Use the path from UCI configuration (where user installed it)
    local save_path = get_kernel_save_path()
    local binary_path = save_path .. "/openlist"
    
    -- Check if binary exists at configured location
    if fs.access(binary_path) then
        return binary_path
    end
    
    -- If not found at configured location, try to detect and update config
    local detected_path, detected_save_path = detect_and_set_kernel_path()
    if detected_path then
        return detected_path
    end
    
    -- Final fallback to default path
    return get_openlist_install_path() .. "/openlist"
end

function get_openlist_version()
    -- First try to detect and set correct path
    local binary_path, save_path = detect_and_set_kernel_path()
    
    if binary_path then
        -- Get version using 'openlist version' command
        local version_cmd = binary_path .. " version 2>/dev/null"
        local output = util.trim(sys.exec(version_cmd))
        
        if output and output ~= "" then
            -- Parse the output line by line to find the "Version:" line specifically
            for line in output:gmatch("[^\r\n]+") do
                local line_trimmed = util.trim(line)
                
                -- Look specifically for "Version:" line (not "Go Version:" or others)
                if line_trimmed:match("^Version:%s*") then
                    local version = line_trimmed:match("^Version:%s*([vV]?[%d]+%.[%d]+%.[%d]+[%w%-%.]*)")
                    if version then
                        local formatted_version = version:match("^[vV]") and version or ("v" .. version)
                        log_openlistui_operation("VERSION_DETECT", "OpenList version detected from Version line: " .. formatted_version)
                        return formatted_version
                    end
                end
            end
            
            -- Fallback: look for WebVersion line if Version line parsing failed
            for line in output:gmatch("[^\r\n]+") do
                local line_trimmed = util.trim(line)
                if line_trimmed:match("^WebVersion:%s*") then
                    local version = line_trimmed:match("^WebVersion:%s*([vV]?[%d]+%.[%d]+%.[%d]+[%w%-%.]*)")
                    if version then
                        local formatted_version = version:match("^[vV]") and version or ("v" .. version)
                        log_openlistui_operation("VERSION_DETECT", "OpenList version detected from WebVersion line: " .. formatted_version)
                        return formatted_version
                    end
                end
            end
            
            -- Additional fallback: look for any version pattern that's NOT from Go Version line
            for line in output:gmatch("[^\r\n]+") do
                local line_trimmed = util.trim(line)
                -- Explicitly skip lines that start with "Go Version:", "Built At:", "Author:", "Commit ID:"
                if not line_trimmed:match("^Go Version:") and 
                   not line_trimmed:match("^Built At:") and 
                   not line_trimmed:match("^Author:") and 
                   not line_trimmed:match("^Commit ID:") then
                    
                    -- Look for standalone version patterns that look like v4.1.0
                    local version = line_trimmed:match("^([vV]?[%d]+%.[%d]+%.[%d]+[%w%-%.]*)")
                    if version and not version:match("^[vV]?1%.[%d]+%.[%d]+") then  -- Skip Go version patterns like 1.24.5
                        local formatted_version = version:match("^[vV]") and version or ("v" .. version)
                        log_openlistui_operation("VERSION_DETECT", "OpenList version detected from pattern match: " .. formatted_version)
                        return formatted_version
                    end
                end
            end
        end
        
        -- Binary exists but can't get version
        log_openlistui_operation("VERSION_UNKNOWN", "OpenList binary found but version unknown")
        return "installed"
    end
    
    log_openlistui_operation("BINARY_NOT_FOUND", "OpenList binary not found in any common location")
    return "Not installed"
end

-- Find OpenList binary in common locations
function find_openlist_binary()
    local common_paths = {
        "/usr/bin/openlist",
        "/usr/local/bin/openlist", 
        "/opt/openlist/openlist",
        "/tmp/openlist",
        "/etc/openlistui/openlist"
    }
    
    for _, path in ipairs(common_paths) do
        if fs.access(path, "x") then
            log_openlistui_operation("BINARY_FOUND", "OpenList binary found at: " .. path)
            return path
        end
    end
    
    log_openlistui_operation("BINARY_SEARCH", "OpenList binary not found in any common location")
    return nil
end

-- Get latest OpenList version from GitHub API
function get_latest_openlist_version()
    log_openlistui_operation("VERSION_CHECK", "Getting latest OpenList version with proxy and cache support")
    
    -- First try to get from cache
    local cache_key = "openlist_latest_version"
    local cached_result = get_cached_response(cache_key)
    if cached_result then
        log_openlistui_operation("VERSION_CACHE", "Using cached OpenList version: " .. cached_result)
        return cached_result
    end
    
    -- Test network connectivity with a lightweight HTTP request instead of ping
    local test_url = "https://api.github.com"
    local proxied_test_url = apply_proxy_to_url(test_url)
    local connectivity_test = util.trim(sys.exec("curl -s --connect-timeout 5 --max-time 10 -I " .. proxied_test_url .. " >/dev/null 2>&1; echo $?"))
    
    if connectivity_test ~= "0" then
        log_openlistui_operation("NETWORK_ERROR", "Network connectivity test failed for api.github.com")
        -- Still try the methods in case the test is unreliable
        log_openlistui_operation("NETWORK_WARNING", "Proceeding anyway as connectivity test may be unreliable")
    end
    
    -- Try multiple methods to get the latest version
    local methods = {
        -- Method 1: GitHub API with timeout and better error handling (using cache and proxy)
        function()
            local url = "https://api.github.com/repos/OpenListTeam/OpenList/releases/latest"
            local extra_params = '-H "Accept: application/vnd.github.v3+json" -H "User-Agent: OpenListUI/1.0"'
            local response = execute_curl_with_cache(url, extra_params)
            
            if response and response ~= "" and not response:match("curl:") and response:match("tag_name") then
                -- More robust JSON parsing
                local tag_name = response:match('"tag_name"%s*:%s*"([^"]+)"')
                if tag_name then
                    -- Remove 'v' prefix if present to normalize version
                    local clean_version = tag_name:gsub("^v", "")
                    log_openlistui_operation("VERSION_API1", "API method 1 found version: " .. tag_name .. " (cleaned: " .. clean_version .. ")")
                    return clean_version
                end
            end
            return nil
        end,
        -- Method 2: GitHub API with simpler parsing (using cache and proxy)
        function()
            local url = "https://api.github.com/repos/OpenListTeam/OpenList/releases/latest"
            local response = execute_curl_with_cache(url)
            
            if response and response ~= "" and response ~= "null" and not response:match("curl:") then
                -- Extract tag_name using grep-like pattern matching
                local tag_name = response:match('"tag_name"%s*:%s*"([^"]+)"')
                if tag_name and tag_name ~= "" then
                    -- Remove 'v' prefix if present
                    local clean_version = tag_name:gsub("^v", "")
                    log_openlistui_operation("VERSION_API2", "API method 2 found version: " .. tag_name .. " (cleaned: " .. clean_version .. ")")
                    return clean_version
                end
            end
            return nil
        end,
        -- Method 3: GitHub releases page scraping as fallback
        function()
            local cmd = 'curl -s --connect-timeout 10 --max-time 30 "https://github.com/OpenListTeam/OpenList/releases/latest" 2>/dev/null | grep -o "OpenListTeam/OpenList/releases/tag/[^\"]*" | head -1 | cut -d"/" -f6'
            local response = util.trim(sys.exec(cmd))
            if response and response ~= "" and not response:match("curl:") then
                -- Remove 'v' prefix if present
                local clean_version = response:gsub("^v", "")
                log_openlistui_operation("VERSION_SCRAPE", "Scraping method found version: " .. response .. " (cleaned: " .. clean_version .. ")")
                return clean_version
            end
            return nil
        end
    }
    
    for i, method in ipairs(methods) do
        local version = method()
        log_openlistui_operation("VERSION_METHOD", "OpenList method " .. i .. " returned: " .. (version or "nil"))
        if version and version ~= "" and version ~= "null" and not version:match("error") then
            log_openlistui_operation("VERSION_SUCCESS", "Successfully got OpenList version: " .. version .. " using method " .. i)
            -- Cache the successful result
            set_cached_response("openlist_latest_version", version)
            return version
        end
    end
    
    log_openlistui_operation("VERSION_FAILED", "Failed to get OpenList latest version - all methods failed")
    return "unknown"
end

-- RClone functionality removed

-- RClone functionality removed

-- Get download URLs for specified architecture and version
function action_get_download_urls()
    local arch = http.formvalue("arch") or get_system_arch()
    local version = http.formvalue("version") or "latest"
    local branch = http.formvalue("branch") or "master"
    
    local result = {}
    result.arch = arch
    result.version = version
    result.branch = branch
    
    -- Get latest version if "latest" is requested
    if version == "latest" then
        local releases = get_github_releases(branch == "dev")
        if #releases > 0 then
            version = releases[1].tag_name
            result.version = version
        end
    end
    
    -- Get OpenList download URLs
    result.openlist = {
        full = get_openlist_download_url(version, false),
        lite = get_openlist_download_url(version, true)
    }
    
    result.success = (result.openlist.full ~= nil)
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Get download URL for a specific component
function action_get_download_url()
    local component = http.formvalue("component") or "openlist"
    local arch = http.formvalue("arch") or get_system_arch()
    local version = http.formvalue("version") or "latest"
    local branch = http.formvalue("branch") or "master"
    local core_type = http.formvalue("core_type") or "full"
    
    log_openlistui_operation("GET_DOWNLOAD_URL", "Getting download URL for " .. component .. " (" .. arch .. ", " .. version .. ")")
    
    local result = {
        success = false,
        component = component,
        arch = arch,
        version = version,
        branch = branch,
        core_type = core_type
    }
    
    -- Get latest version if "latest" is requested
    if version == "latest" then
        if component == "openlist" then
            local latest_version = get_latest_openlist_version()
            if latest_version ~= "unknown" and latest_version ~= "Network error" then
                version = latest_version
                result.version = version
            else
                result.message = "Failed to get latest version: " .. latest_version
                http.prepare_content("application/json")
                http.write_json(result)
                return
            end
        elseif component == "luci" then
            local latest_version = get_latest_luci_version()
            if latest_version ~= "unknown" then
                version = latest_version
                result.version = version
            else
                result.message = "Failed to get latest LuCI version"
                http.prepare_content("application/json")
                http.write_json(result)
                return
            end
        end
    end
    
    -- Build download URL based on component
    if component == "openlist" then
        local use_lite = (core_type == "lite")
        local download_url = get_openlist_download_url(version, use_lite, arch)
        if download_url then
            result.success = true
            result.download_url = download_url
            result.message = "Download URL generated successfully"
        else
            result.message = "Failed to generate OpenList download URL"
        end
    elseif component == "luci" then
        local download_url = get_luci_download_url(version)
        if download_url then
            result.success = true
            result.download_url = download_url
            result.message = "LuCI download URL generated successfully"
        else
            result.message = "Failed to generate LuCI download URL"
        end
    else
        result.message = "Unknown component: " .. component
    end
    
    log_openlistui_operation("GET_DOWNLOAD_URL", "Download URL result: " .. (result.success and "success" or "failed") .. " - " .. (result.message or ""))
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Get OpenList download URL for specific architecture
function get_openlist_download_url(version, use_lite, arch)
    -- Use default architecture if not provided
    if not arch then
        arch = get_system_arch()
    end
    
    if not version or version == "unknown" or version == "Network error" then
        log_openlistui_operation("DOWNLOAD_URL", "Invalid version: " .. (version or "nil"))
        return nil
    end
    
    -- Map architecture to GitHub release naming convention
    local github_arch = map_arch_to_github_release(arch)
    
    -- Ensure version has 'v' prefix for GitHub URLs
    local version_tag = version
    if not version_tag:match("^v") then
        version_tag = "v" .. version_tag
    end
    
    -- Build binary name with correct format
    local suffix = use_lite and "-lite" or ""
    local filename = "openlist-" .. github_arch .. suffix
    
    -- Determine file extension based on OS
    local file_extension = ".tar.gz"  -- Default for Linux
    if github_arch:match("windows") then
        file_extension = ".zip"
    end
    
    local full_filename = filename .. file_extension
    
    -- Build download URL
    local download_url = string.format("https://github.com/OpenListTeam/OpenList/releases/download/%s/%s", version_tag, full_filename)
    
    log_openlistui_operation("DOWNLOAD_URL", "Generated OpenList download URL: " .. download_url)
    log_openlistui_operation("DOWNLOAD_URL", "Parameters - version: " .. version .. ", original_arch: " .. arch .. ", mapped_arch: " .. github_arch .. ", lite: " .. tostring(use_lite))
    
    return download_url
end

-- Get LuCI download URL for specific version
function get_luci_download_url(version)
    if not version or version == "unknown" then
        log_openlistui_operation("LUCI_DOWNLOAD_URL", "Invalid version: " .. (version or "nil"))
        return nil
    end
    
    local arch = get_system_arch()
    if not arch then
        log_openlistui_operation("LUCI_DOWNLOAD_URL", "Unable to detect system architecture")
        return nil
    end
    
    -- Use LuCI-specific architecture mapping
    local mapped_arch = map_arch_to_luci_ipk(arch)
    if not mapped_arch then
        log_openlistui_operation("LUCI_DOWNLOAD_URL", "Unsupported architecture: " .. arch)
        return nil
    end
    
    -- Ensure version has 'v' prefix for GitHub URLs
    local version_tag = version
    if not version_tag:match("^v") then
        version_tag = "v" .. version_tag
    end
    
    -- Build download URL for IPK file
    local ipk_filename = string.format("luci-app-openlistui_v%s_%s.ipk", version, mapped_arch)
    local download_url = string.format("https://github.com/drfccv/luci-app-openlistui/releases/download/%s/%s", 
        version_tag, ipk_filename)
    
    log_openlistui_operation("LUCI_DOWNLOAD_URL", "Generated LuCI download URL: " .. download_url)
    log_openlistui_operation("LUCI_DOWNLOAD_URL", "Parameters - version: " .. version .. ", arch: " .. arch .. ", mapped_arch: " .. mapped_arch)
    
    return download_url
end

-- Get RClone download URL for specific architecture
-- RClone functionality removed

-- API endpoint to get kernel save path
function action_get_kernel_save_path()
    local result = {}
    result.success = true
    result.path = get_kernel_save_path()
    
    -- Add debug logging
    log_openlistui_operation("API_CALL", "get_kernel_save_path called, returning: " .. result.path)
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- API endpoint to get version information
function action_get_version_info()
    -- Add logging to debug
    log_openlistui_operation("API_CALL", "action_get_version_info called")
    
    local result = {}
    result.success = true
    
    -- Get current versions
    local openlist_current = get_openlist_version()
    
    log_openlistui_operation("VERSION_INFO", "Current versions - OpenList: " .. (openlist_current or "nil"))
    
    -- Get latest versions
    local openlist_latest = get_latest_openlist_version()
    
    log_openlistui_operation("VERSION_INFO", "Latest versions - OpenList: " .. (openlist_latest or "nil"))
    
    -- Determine if updates are available
    local openlist_update_available = false
    
    -- Only show update available if we have valid current and latest versions
    if openlist_current ~= "Not found" and openlist_current ~= "unknown" and openlist_current ~= "No kernel found" and
       openlist_latest ~= "unknown" and openlist_latest ~= "Unknown" and openlist_latest ~= "" and
       openlist_current ~= openlist_latest then
        openlist_update_available = true
    end
    
    result.openlist = {
        current = openlist_current,
        latest = openlist_latest,
        update_available = openlist_update_available
    }
    
    result.system_arch = get_system_arch()
    result.kernel_save_path = get_kernel_save_path()
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Simple test endpoint
function action_test()
    log_openlistui_operation("API_CALL", "Test endpoint called")
    
    local result = {
        success = true,
        message = "Test endpoint working",
        timestamp = os.time()
    }
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Test GitHub token validity and rate limits
function action_test_github_token()
    local result = {}
    local github_token = get_github_token()
    
    if not github_token then
        result.success = false
        result.message = "No GitHub token configured"
        result.rate_limit = "N/A"
        result.authenticated = false
    else
        -- Test the token by checking rate limit
        local url = "https://api.github.com/rate_limit"
        local headers = '-H "Accept: application/vnd.github.v3+json" -H "User-Agent: OpenListUI/1.0"'
        local cmd = 'curl -s --connect-timeout 10 --max-time 30 -H "Authorization: token ' .. github_token .. '" ' .. headers .. ' "' .. url .. '" 2>/dev/null'
        
        log_openlistui_operation("GITHUB_TOKEN_TEST", "Testing GitHub token validity")
        local response = util.trim(sys.exec(cmd))
        
        if response and response ~= "" and not response:match("^curl:") then
            -- Try to parse the rate limit info
            local core_limit = response:match('"core":%s*{[^}]*"limit":%s*(%d+)')
            local core_remaining = response:match('"core":%s*{[^}]*"remaining":%s*(%d+)')
            local core_reset = response:match('"core":%s*{[^}]*"reset":%s*(%d+)')
            
            if core_limit then
                result.success = true
                result.message = "GitHub token is valid and working"
                result.authenticated = true
                result.rate_limit = {
                    limit = tonumber(core_limit) or 0,
                    remaining = tonumber(core_remaining) or 0,
                    reset_time = tonumber(core_reset) or 0
                }
                
                -- Calculate reset time in human readable format
                if result.rate_limit.reset_time > 0 then
                    local reset_date = os.date("%Y-%m-%d %H:%M:%S", result.rate_limit.reset_time)
                    result.rate_limit.reset_date = reset_date
                end
                
                log_openlistui_operation("GITHUB_TOKEN_SUCCESS", 
                    string.format("Token valid - Limit: %d, Remaining: %d", 
                    result.rate_limit.limit, result.rate_limit.remaining))
            else
                result.success = false
                result.message = "GitHub token response received but unable to parse rate limit info"
                result.authenticated = false
                result.rate_limit = "Parse error"
                result.debug_response = response:sub(1, 200) -- First 200 chars for debugging
            end
        else
            result.success = false
            result.message = "Failed to contact GitHub API or invalid token"
            result.authenticated = false
            result.rate_limit = "API error"
            if response and response ~= "" then
                result.error_details = response:sub(1, 200) -- First 200 chars for debugging
            end
        end
    end
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Get cache status for debugging
function action_cache_status()
    local result = {}
    local stats = get_cache_stats()
    
    result.success = true
    result.cache = stats
    result.message = string.format("Cache contains %d entries (%d valid, %d expired)", 
                                   stats.total, stats.valid, stats.expired)
    
    -- Add detailed cache info for debugging
    result.cache_details = {}
    for key, entry in pairs(github_cache) do
        local age_seconds = os.time() - entry.timestamp
        result.cache_details[key] = {
            age_seconds = age_seconds,
            is_valid = is_cache_valid(entry.timestamp),
            expires_in = cache_ttl - age_seconds
        }
    end
    
    log_openlistui_operation("CACHE_STATUS", result.message)
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Get settings configuration
function action_settings_get()
    local result = {}
    
    -- Get all openlistui configuration sections
    local config = {}
    
    -- Main service section
    config.main = {}
    config.main.port = uci:get("openlistui", "main", "port") or "5244"
    config.main.data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
    config.main.enable_https = uci:get("openlistui", "main", "enable_https") or "0"
    config.main.https_port = uci:get("openlistui", "main", "https_port") or "5443"
    config.main.force_https = uci:get("openlistui", "main", "force_https") or "0"
    config.main.cors_enabled = uci:get("openlistui", "main", "cors_enabled") or "0"
    config.main.auto_start = uci:get("openlistui", "main", "auto_start") or "0"
    config.main.admin_password = uci:get("openlistui", "main", "admin_password") or ""
    

    
    -- Integration section
    config.integration = {}
    config.integration.github_proxy = uci:get("openlistui", "integration", "github_proxy") or ""
    config.integration.github_token = uci:get("openlistui", "integration", "github_token") or ""
    config.integration.kernel_save_path = uci:get("openlistui", "integration", "kernel_save_path") or "/tmp/openlist"
    
    result.success = true
    result.config = config
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Save settings configuration
function action_settings_save()
    local req = http.content()
    local data = json.parse(req)
    local result = {}
    
    log_openlistui_operation("SETTINGS_SAVE", "Attempting to save configuration settings")
    
    if not data or not data.config then
        result.success = false
        result.message = "Invalid request data"
        log_openlistui_operation("SETTINGS_SAVE_FAILED", "Invalid request data")
        http.prepare_content("application/json")
        http.write(json_encode(result))
        return
    end
    
    local config = data.config
    local success = true
    local error_msg = ""
    
    -- Ensure UCI sections exist
    if not uci:get("openlistui", "main") then
        uci:set("openlistui", "main", "openlistui")
    end

    if not uci:get("openlistui", "integration") then
        uci:set("openlistui", "integration", "openlistui")
    end
    
    -- Save main section
    if config.main then
        for key, value in pairs(config.main) do
            if key ~= "admin_password" or (value and value ~= "") then
                uci:set("openlistui", "main", key, value)
            end
        end
        
        -- Handle firewall rules for external access
        if config.main.cors_enabled then
            local rule_name = "openlist_external_access"
            
            -- Remove existing rule first
            uci:delete("firewall", rule_name)
            
            if config.main.cors_enabled == "1" then
                -- Read ports from config.json
                local data_dir = config.main and config.main.data_dir or "/etc/openlistui"
                local config_file = data_dir .. "/data/config.json"
                local ports = {
                    http_port = "5244",
                    https_port = nil,
                    ftp_port = "5221", 
                    sftp_port = "5222",
                    s3_port = "5246"
                }
                
                if fs.access(config_file) then
                    local content = fs.readfile(config_file)
                    if content then
                        local json_config = json_decode(content)
                        if json_config then
                            if json_config.scheme then
                                if json_config.scheme.http_port then
                                    ports.http_port = tostring(json_config.scheme.http_port)
                                end
                                if json_config.scheme.https_port and json_config.scheme.https_port > 0 then
                                    ports.https_port = tostring(json_config.scheme.https_port)
                                end
                            end
                            if json_config.ftp and json_config.ftp.listen then
                                local ftp_listen = json_config.ftp.listen
                                local ftp_port = ftp_listen:match(":(%d+)")
                                if ftp_port then
                                    ports.ftp_port = ftp_port
                                end
                            end
                            if json_config.sftp and json_config.sftp.listen then
                                local sftp_listen = json_config.sftp.listen
                                local sftp_port = sftp_listen:match(":(%d+)")
                                if sftp_port then
                                    ports.sftp_port = sftp_port
                                end
                            end
                            if json_config.s3 and json_config.s3.port then
                                ports.s3_port = tostring(json_config.s3.port)
                            end
                        end
                    end
                end
                
                local dest_ports = ports.http_port .. " " .. ports.ftp_port .. " " .. ports.sftp_port .. " " .. ports.s3_port
                if ports.https_port then
                    dest_ports = dest_ports .. " " .. ports.https_port
                end
                
                -- Add firewall rule to allow external access
                uci:set("firewall", rule_name, "rule")
                uci:set("firewall", rule_name, "name", "openlist")
                uci:set("firewall", rule_name, "src", "wan")
                uci:set("firewall", rule_name, "proto", "tcp")
                uci:set("firewall", rule_name, "dest_port", dest_ports)
                uci:set("firewall", rule_name, "target", "ACCEPT")
                uci:set("firewall", rule_name, "enabled", "1")
            end
            
            -- Commit firewall changes
            uci:commit("firewall")
            
            -- Restart firewall to apply changes
            sys.call("/etc/init.d/firewall restart >/dev/null 2>&1 &")
        end
    end
    

    
    -- Save integration section
    if config.integration then
        for key, value in pairs(config.integration) do
            if key == "kernel_save_path" then
                -- Add debug logging for kernel_save_path changes
                local current_path = uci:get("openlistui", "integration", "kernel_save_path")
                if current_path ~= value then
                    log_openlistui_operation("CONFIG_CHANGE", string.format("Kernel save path changed from %s to %s", 
                        current_path or "nil", value or "nil"))
                end
            end
            uci:set("openlistui", "integration", key, value)
        end
    end
    
    -- Commit changes
    if not uci:commit("openlistui") then
        success = false
        error_msg = "Failed to save configuration"
    end
    
    -- Create necessary directories after saving configuration
    if success then
        local data_dir = config.main and config.main.data_dir or "/etc/openlistui"
        local kernel_save_path = config.integration and config.integration.kernel_save_path or "/tmp/openlist"
        local port = config.main and config.main.port or "5244"
        
        -- Create main data directory
        sys.exec("mkdir -p '" .. data_dir .. "'")
        sys.exec("chmod 755 '" .. data_dir .. "'")
        
        -- Create data subdirectory
        sys.exec("mkdir -p '" .. data_dir .. "/data'")
        sys.exec("chmod 755 '" .. data_dir .. "/data'")
        
        -- Create backup directory
        sys.exec("mkdir -p '" .. data_dir .. "/backup'")
        sys.exec("chmod 755 '" .. data_dir .. "/backup'")
        
        -- Create kernel save directory
        sys.exec("mkdir -p '" .. kernel_save_path .. "'")
        sys.exec("chmod 755 '" .. kernel_save_path .. "'")
        
        -- Update config.json with new settings
        local cache_dir = config.main and config.main.cache_dir or "/tmp/openlistui"
        local enable_https = config.main and config.main.enable_https or "0"
        local https_port = config.main and config.main.https_port or "5443"
        local force_https = config.main and config.main.force_https or "0"
        local config_file = data_dir .. "/data/config.json"
        if fs.access(config_file) then
            -- Update basic settings
            sys.exec("sed -i 's/\"http_port\": [0-9]*/\"http_port\": " .. port .. "/g' '" .. config_file .. "'")
            sys.exec("sed -i 's|\"temp_dir\": \"[^\"]*\"|\"temp_dir\": \"" .. cache_dir .. "\"|g' '" .. config_file .. "'")
            
            -- Update HTTPS settings
            if enable_https == "1" then
                local force_https_bool = (force_https == "1") and "true" or "false"
                local cert_path = data_dir .. "/data/cert.crt"
                local key_path = data_dir .. "/data/key.key"
                
                -- Update HTTPS port
                sys.exec("sed -i 's/\"https_port\": [0-9-]*/\"https_port\": " .. https_port .. "/g' '" .. config_file .. "'")
                
                -- Update force_https
                sys.exec("sed -i 's/\"force_https\": [a-z]*/\"force_https\": " .. force_https_bool .. "/g' '" .. config_file .. "'")
                
                -- Update certificate paths
                sys.exec("sed -i 's|\"cert_file\": \"[^\"]*\"|\"cert_file\": \"" .. cert_path .. "\"|g' '" .. config_file .. "'")
                sys.exec("sed -i 's|\"key_file\": \"[^\"]*\"|\"key_file\": \"" .. key_path .. "\"|g' '" .. config_file .. "'")
            else
                -- Disable HTTPS
                sys.exec("sed -i 's/\"https_port\": [0-9]*/\"https_port\": -1/g' '" .. config_file .. "'")
                sys.exec("sed -i 's/\"force_https\": [a-z]*/\"force_https\": false/g' '" .. config_file .. "'")
                sys.exec("sed -i 's|\"cert_file\": \"[^\"]*\"|\"cert_file\": \"\"|g' '" .. config_file .. "'")
                sys.exec("sed -i 's|\"key_file\": \"[^\"]*\"|\"key_file\": \"\"|g' '" .. config_file .. "'")
            end
        end
        
        -- Re-apply firewall rules if external access is enabled and config.json was updated
        local cors_enabled = config.main and config.main.cors_enabled
        if cors_enabled == "1" and fs.access(config_file) then
            local rule_name = "openlist_external_access"
            
            -- Remove existing rule first
            uci:delete("firewall", rule_name)
            
            -- Read updated ports from config.json
            local ports = {
                http_port = "5244",
                https_port = nil,
                ftp_port = "5221", 
                sftp_port = "5222",
                s3_port = "5246"
            }
            
            local content = fs.readfile(config_file)
            if content then
                local json_config = json_decode(content)
                if json_config then
                    if json_config.scheme then
                        if json_config.scheme.http_port then
                            ports.http_port = tostring(json_config.scheme.http_port)
                        end
                        if json_config.scheme.https_port and json_config.scheme.https_port > 0 then
                            ports.https_port = tostring(json_config.scheme.https_port)
                        end
                    end
                    if json_config.ftp and json_config.ftp.listen then
                        local ftp_listen = json_config.ftp.listen
                        local ftp_port = ftp_listen:match(":(%d+)")
                        if ftp_port then
                            ports.ftp_port = ftp_port
                        end
                    end
                    if json_config.sftp and json_config.sftp.listen then
                        local sftp_listen = json_config.sftp.listen
                        local sftp_port = sftp_listen:match(":(%d+)")
                        if sftp_port then
                            ports.sftp_port = sftp_port
                        end
                    end
                    if json_config.s3 and json_config.s3.port then
                        ports.s3_port = tostring(json_config.s3.port)
                    end
                end
            end
            
            local dest_ports = ports.http_port .. " " .. ports.ftp_port .. " " .. ports.sftp_port .. " " .. ports.s3_port
            if ports.https_port then
                dest_ports = dest_ports .. " " .. ports.https_port
            end
            
            -- Add updated firewall rule
            uci:set("firewall", rule_name, "rule")
            uci:set("firewall", rule_name, "name", "openlist")
            uci:set("firewall", rule_name, "src", "wan")
            uci:set("firewall", rule_name, "proto", "tcp")
            uci:set("firewall", rule_name, "dest_port", dest_ports)
            uci:set("firewall", rule_name, "target", "ACCEPT")
            uci:set("firewall", rule_name, "enabled", "1")
            
            -- Commit firewall changes
            uci:commit("firewall")
            
            -- Restart firewall to apply changes
            sys.call("/etc/init.d/firewall restart >/dev/null 2>&1 &")
        end
    end
    
    -- Apply settings - restart service if it's running
    if success then
        local status_result = {}
        action_status_internal(status_result)
        if status_result.running then
            -- Service is running, restart it to apply new settings
            sys.call("sleep 1 && /etc/init.d/openlistui restart &")
        end
    end
    
    result.success = success
    if not success then
        result.message = error_msg
        log_openlistui_operation("SETTINGS_SAVE_FAILED", error_msg)
    else
        result.message = "Settings saved successfully"
        log_openlistui_operation("SETTINGS_SAVE_SUCCESS", "Configuration settings saved and applied")
    end
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Generate random password
function action_generate_password()
    local result = {}
    
    -- Generate a secure random password (12 characters, alphanumeric + special chars)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*"
    local password = ""
    
    -- Use /dev/urandom for better randomness
    local urandom = io.open("/dev/urandom", "rb")
    if urandom then
        for i = 1, 12 do
            local byte = urandom:read(1):byte()
            local index = (byte % #chars) + 1
            password = password .. chars:sub(index, index)
        end
        urandom:close()
    else
        -- Fallback to math.random
        math.randomseed(os.time())
        for i = 1, 12 do
            local index = math.random(1, #chars)
            password = password .. chars:sub(index, index)
        end
    end
    
    result.success = true
    result.password = password
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Test RClone configuration
-- RClone functionality removed

-- Internal status function for use by other functions
function action_status_internal(result)
    if not result then
        result = {}
    end
    
    local openlist_running = false
    local pid = nil
    
    -- Get version and installation info first
    result.version = get_openlist_version()
    result.install_path = get_openlist_install_path()
    result.binary_exists = fs.access(get_openlist_binary_path())
    
    -- Only check for running processes if binary exists and version is valid
    if result.binary_exists and result.version ~= "Not installed" and result.version ~= "unknown" then
        -- Check if OpenList is running from our specific install directory
        local binary_path = get_openlist_binary_path()
        local pid_output = util.trim(sys.exec("pgrep -f '" .. binary_path .. "' 2>/dev/null | head -1"))
        
        -- Verify the PID actually belongs to our binary
        if pid_output and pid_output ~= "" then
            local check_pid = tonumber(pid_output)
            if check_pid then
                -- Double-check that the process executable is our binary
                local proc_exe = util.trim(sys.exec("readlink -f /proc/" .. check_pid .. "/exe 2>/dev/null"))
                if proc_exe == binary_path then
                    openlist_running = true
                    pid = check_pid
                end
            end
        end
    else
        -- Binary doesn't exist or not properly installed, definitely not running
        openlist_running = false
    end
    
    result.running = openlist_running
    
    if openlist_running and pid then
        result.pid = pid
        result.port = uci:get("openlistui", "main", "port") or "5244"
        result.uptime = get_process_uptime(pid)
    else
        result.pid = nil
        result.uptime = nil
    end
    
    return result
end

-- New OpenClash-style update endpoints
function action_update_info()
    local result = {}
    
    -- Load saved configuration with defaults
    result.target_arch = uci:get("openlistui", "integration", "target_arch") or get_system_arch()
    result.release_branch = uci:get("openlistui", "integration", "release_branch") or "master"
    result.core_type = uci:get("openlistui", "integration", "core_type") or "full"
    
    -- Additional system info
    result.system_arch = get_system_arch()
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

function action_update()
    local result = {}
    
    -- Get system architecture
    result.system_arch = get_system_arch()
    
    -- Get current versions
    result.openlist_current = get_openlist_version()

    
    -- Try to get latest versions using GitHub API
    local openlist_latest = "unknown"

    
    -- Check if curl is available
    local curl_test = sys.exec("which curl >/dev/null 2>&1; echo $?")
    local curl_available = curl_test and curl_test:match("^0")
    
    if curl_available then
        log_openlistui_operation("VERSION_CHECK", "Using curl to fetch latest versions from GitHub API (no proxy for API calls)")
        
        -- Try to get OpenList latest version using cached method (no proxy for API)
        local openlist_url = "https://api.github.com/repos/OpenListTeam/OpenList/releases/latest"
        local openlist_headers = "-H 'User-Agent: OpenListUI/1.0'"
        local openlist_response = execute_curl_with_cache(openlist_url, "openlist_latest_quick", openlist_headers)
        
        -- Log for debugging
        log_openlistui_operation("VERSION_CHECK", "OpenList API response received: " .. (openlist_response and "success" or "failed"))
        
        if openlist_response and openlist_response ~= "" and not openlist_response:match("curl:") and openlist_response:match("tag_name") then
            -- 兼容所有可能的 JSON 格式
            local tag_match = openlist_response:match('"tag_name"%s*:%s*"([^"]+)"')
            if not tag_match then
                tag_match = openlist_response:match('"tag_name"%s*:%s*\'([^\']+)\'')
            end
            if not tag_match then
                tag_match = openlist_response:match('"tag_name"%s*:%s*([^\n,}]+)')
            end
            if tag_match and tag_match ~= "" then
                openlist_latest = tag_match
                log_openlistui_operation("VERSION_CHECK", "OpenList latest version found: " .. openlist_latest)
            else
                openlist_latest = "unknown"
                log_openlistui_operation("ERROR", "Failed to parse OpenList version from API response. Raw: " .. openlist_response)
            end
        else
            openlist_latest = "unknown"
            log_openlistui_operation("ERROR", "Failed to fetch OpenList version or API response was invalid. Raw: " .. (openlist_response or "nil"))
        end
        

    else
        -- No curl available, explicitly set to unknown
        openlist_latest = "unknown"

        log_openlistui_operation("ERROR", "curl is not available, cannot check for updates.")
    end
    
    result.openlist_latest = openlist_latest

    -- Get LuCI app version information
    result.luci_current = get_current_luci_version()
    result.luci_latest = get_latest_luci_version()
    
    -- Check if LuCI app update is available
    result.luci_update_available = false
    if result.luci_current ~= "unknown" and result.luci_latest ~= "unknown" and 
       result.luci_current ~= result.luci_latest then
        result.luci_update_available = true
    end
    
    -- Package information
    result.openlist_package_date = os.date("%Y-%m-%d")
    result.kernel_save_path = get_kernel_save_path()
    
    result.success = true
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- RClone functionality removed

-- Download OpenList binary
function download_openlist(version, use_lite)
    if not version or version == "unknown" or version == "Network error" then
        log_openlistui_operation("CORE_UPDATE_ERROR", "Invalid version specified: " .. (version or "nil"))
        return false, "Invalid version specified"
    end
    
    log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "Downloading OpenList " .. version .. " (" .. (use_lite and "lite" or "full") .. ")")
    
    local arch = get_system_arch()
    if not arch then
        log_openlistui_operation("CORE_UPDATE_ERROR", "Unsupported architecture detected")
        return false, "Unsupported architecture"
    end
    
    local github_arch = map_arch_to_github_release(arch)
    local kernel_save_path = get_kernel_save_path()
    sys.exec("mkdir -p '" .. kernel_save_path .. "'")
    
    local suffix = use_lite and "-lite" or ""
    local filename = "openlist-" .. github_arch .. suffix
    
    local file_extension = ".tar.gz"
    if github_arch:match("windows") then
        file_extension = ".zip"
    end
    
    local full_filename = filename .. file_extension
    
    local version_tag = version
    if not version_tag:match("^v") then
        version_tag = "v" .. version_tag
    end
    
    local download_url = string.format("https://github.com/OpenListTeam/OpenList/releases/download/%s/%s", version_tag, full_filename)
    
    local urls = {
        download_url,
        string.format("https://github.com/OpenListTeam/OpenList/releases/download/%s/openlist-%s%s%s", version_tag, github_arch, suffix, file_extension),
        string.format("https://github.com/OpenListTeam/OpenList/releases/latest/download/%s", full_filename),
        string.format("https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-%s%s%s", github_arch, suffix, file_extension)
    }
    
    for i, url in ipairs(urls) do
        log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "Attempt " .. i .. "/" .. #urls .. ": " .. url)
        
        -- Generate temp file name with correct extension based on URL
        local temp_file = kernel_save_path .. "/openlist-download" .. file_extension
        log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "Temporary file: " .. temp_file)
        
        -- Apply proxy to the URL
        local proxied_url = apply_proxy_to_url(url)
        if proxied_url ~= url then
            log_openlistui_operation("CORE_UPDATE_PROXY", "Applied proxy to URL " .. i .. ": " .. proxied_url)
        else
            log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "No proxy configured for URL " .. i)
        end
        
        -- First check if URL exists with HEAD request
        log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "Checking URL accessibility with HEAD request")
        local head_cmd = string.format("curl -I --connect-timeout 10 --max-time 30 '%s' 2>/dev/null | head -1", proxied_url)
        local head_response = util.trim(sys.exec(head_cmd))
        log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "HEAD response for URL " .. i .. ": " .. (head_response or "empty"))
        
        -- Accept both 200 OK and 302 redirect (common for GitHub releases)
        if head_response and (head_response:match("200") or head_response:match("302")) then
            log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "URL " .. i .. " is accessible, starting download")
            local cmd = string.format("curl -L --connect-timeout 30 --max-time 300 -o '%s' '%s' 2>/dev/null", temp_file, proxied_url)
            log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "Download command: " .. cmd)
            local ret = sys.call(cmd)
            
            if ret == 0 and fs.access(temp_file) then
                local file_size = fs.stat(temp_file)
                if file_size and file_size.size > 1000 then -- At least 1KB
                    log_openlistui_operation("CORE_UPDATE_SUCCESS", "Successfully downloaded from URL " .. i .. " (" .. file_size.size .. " bytes)")
                    return true, temp_file
                else
                    log_openlistui_operation("CORE_UPDATE_ERROR", "Downloaded file too small: " .. (file_size and file_size.size or "0") .. " bytes")
                end
            else
                log_openlistui_operation("CORE_UPDATE_ERROR", "Download failed for URL " .. i .. ", curl returned: " .. ret)
            end
        else
            log_openlistui_operation("CORE_UPDATE_WARNING", "Skipping URL " .. i .. " - not accessible (HEAD response: " .. (head_response or "none") .. ")")
        end
        
        -- Clean up failed download attempt
        log_openlistui_operation("CORE_UPDATE_DOWNLOAD", "Cleaning up failed download attempt")
        sys.exec("rm -f '" .. temp_file .. "'")
    end
    
    log_openlistui_operation("CORE_UPDATE_ERROR", "All " .. #urls .. " download URLs failed for Core update")
    return false, "Failed to download OpenList binary from all available sources"
end

-- Install OpenList binary
function install_openlist(binary_path)
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Starting Core installation process")
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Binary path: " .. (binary_path or "none"))
    
    if not binary_path or not fs.access(binary_path) then
        log_openlistui_operation("CORE_UPDATE_ERROR", "Binary file not found or not accessible: " .. (binary_path or "none"))
        return false, "Binary file not found"
    end
    
    local install_dir = get_kernel_save_path()
    local final_path = install_dir .. "/openlist"
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Install directory: " .. install_dir)
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Final binary path: " .. final_path)
    
    -- Make sure install directory exists
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Creating install directory if needed")
    sys.exec("mkdir -p '" .. install_dir .. "'")
    
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Extracting downloaded file: " .. binary_path)
    
    -- Check if the file is a tar.gz archive
    if binary_path:match("%.tar%.gz$") then
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Detected tar.gz archive format")
        -- Extract tar.gz file
        local extract_cmd = string.format("cd '%s' && tar -xzf '%s'", install_dir, binary_path)
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Extract command: " .. extract_cmd)
        local extract_ret = sys.call(extract_cmd)
        if extract_ret ~= 0 then
            log_openlistui_operation("CORE_UPDATE_ERROR", "Failed to extract tar.gz file, return code: " .. extract_ret)
            return false, "Failed to extract downloaded archive"
        end
        log_openlistui_operation("CORE_UPDATE_INSTALL", "tar.gz extraction completed successfully")
        
        -- Look for the extracted binary (it should be named 'openlist')
        local extracted_binary = install_dir .. "/openlist"
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Looking for extracted binary at: " .. extracted_binary)
        if not fs.access(extracted_binary) then
            log_openlistui_operation("CORE_UPDATE_ERROR", "Extracted binary not found at expected location: " .. extracted_binary)
            return false, "Extracted binary not found"
        end
        
        log_openlistui_operation("CORE_UPDATE_SUCCESS", "Successfully extracted binary to " .. extracted_binary)
        
    elseif binary_path:match("%.zip$") then
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Detected zip archive format")
        -- Extract zip file
        local extract_cmd = string.format("cd '%s' && unzip -o '%s'", install_dir, binary_path)
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Extract command: " .. extract_cmd)
        local extract_ret = sys.call(extract_cmd)
        if extract_ret ~= 0 then
            log_openlistui_operation("CORE_UPDATE_ERROR", "Failed to extract zip file, return code: " .. extract_ret)
            return false, "Failed to extract downloaded archive"
        end
        log_openlistui_operation("CORE_UPDATE_INSTALL", "zip extraction completed successfully")
        
        -- Look for the extracted binary
        local extracted_binary = install_dir .. "/openlist"
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Looking for extracted binary at: " .. extracted_binary)
        if not fs.access(extracted_binary) then
            log_openlistui_operation("CORE_UPDATE_ERROR", "Extracted binary not found at expected location: " .. extracted_binary)
            return false, "Extracted binary not found"
        end
        
        log_openlistui_operation("CORE_UPDATE_SUCCESS", "Successfully extracted binary to " .. extracted_binary)
        
    else
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Detected direct binary file, copying to final location")
        -- Assume it's already a binary file, just copy it
        local copy_cmd = string.format("cp '%s' '%s'", binary_path, final_path)
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Copy command: " .. copy_cmd)
        local ret = sys.call(copy_cmd)
        if ret ~= 0 then
            log_openlistui_operation("CORE_UPDATE_ERROR", "Failed to copy binary to installation directory, return code: " .. ret)
            return false, "Failed to copy binary to installation directory"
        end
        log_openlistui_operation("CORE_UPDATE_SUCCESS", "Successfully copied binary to " .. final_path)
    end
    
    -- Make executable
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Setting executable permissions for binary")
    sys.exec("chmod +x '" .. final_path .. "'")
    
    -- Verify installation
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Verifying installation at: " .. final_path)
    if not fs.access(final_path) then
        log_openlistui_operation("CORE_UPDATE_ERROR", "Installation verification failed - binary not accessible")
        return false, "Installation verification failed"
    end
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Binary file verification passed")
    
    -- Test if binary is working
    local test_cmd = final_path .. " --version >/dev/null 2>&1"
    local test_ret = sys.call(test_cmd)
    if test_ret ~= 0 then
        log_openlistui_operation("CORE_UPDATE_ERROR", "Binary installed but functionality test failed (return code: " .. test_ret .. ")")
        return false, "Binary installed but not functional (version check failed)"
    else
        log_openlistui_operation("CORE_UPDATE_INSTALL", "Binary functionality test passed")
    end
    
    -- Update kernel save path in UCI to point to where we installed it
    log_openlistui_operation("CORE_UPDATE_INSTALL", "Updating UCI configuration with install path: " .. install_dir)
    uci:set("openlistui", "integration", "kernel_save_path", install_dir)
    uci:commit("openlistui")
    log_openlistui_operation("CORE_UPDATE_INSTALL", "UCI configuration updated successfully")
    
    log_openlistui_operation("CORE_UPDATE_SUCCESS", "Core installation completed successfully at " .. final_path)
    return true, "Installation completed successfully"
end

-- Update OpenList (stub function for compatibility)
function update_openlist()
    local latest_version = get_latest_openlist_version()
    if latest_version == "unknown" or latest_version == "Network error" then
        return false
    end
    
    local success, message = download_openlist(latest_version, false)
    if not success then
        return false
    end
    
    return install_openlist(message)
end

-- RClone functionality removed

-- Component update action (for front-end update buttons)
function action_component_update()
    local component = luci.http.formvalue("component")
    local core_type = luci.http.formvalue("core_type") or "full"  -- Get core_type parameter
    local use_lite = (core_type == "lite")  -- Determine if lite version should be used
    
    log_openlistui_operation("COMPONENT_UPDATE", "Starting update for component: " .. (component or "unknown") .. ", core_type: " .. core_type)
    
    local result = {
        success = false,
        message = "Update failed",
        component = component,
        core_type = core_type
    }
    
    if not component then
        result.message = "No component specified"
        http.prepare_content("application/json")
        http.write(json_encode(result))
        return
    end
    
    if component == "openlist" then
        -- Update OpenList
        log_openlistui_operation("OPENLIST_UPDATE", "Attempting to update OpenList core (" .. (use_lite and "lite" or "full") .. " version)")
        
        -- First check if OpenList is installed
        local current_version = get_openlist_version()
        if current_version == "Not installed" then
            log_openlistui_operation("OPENLIST_UPDATE", "OpenList not installed, attempting first-time installation")
            
            -- Get latest version for installation
            local latest_version = get_latest_openlist_version()
            if latest_version == "unknown" or latest_version == "Network error" then
                result.success = false
                result.message = "Failed to get latest OpenList version: " .. latest_version
            else
                log_openlistui_operation("OPENLIST_INSTALL", "Installing OpenList version: " .. latest_version .. " (" .. (use_lite and "lite" or "full") .. ")")
                local download_success, download_path = download_openlist(latest_version, use_lite)
                if download_success then
                    local install_success, install_message = install_openlist(download_path)
                    result.success = install_success
                    result.message = install_success and ("OpenList " .. (use_lite and "lite " or "") .. "installed successfully") or ("Installation failed: " .. (install_message or "Unknown error"))
                    -- Clean up downloaded file
                    sys.exec("rm -f '" .. download_path .. "'")
                else
                    result.success = false
                    result.message = "Failed to download OpenList: " .. (download_path or "Unknown error")
                end
            end
        else
            log_openlistui_operation("OPENLIST_UPDATE", "OpenList already installed (version: " .. current_version .. "), attempting update")
            
            -- Get latest version for update
            local latest_version = get_latest_openlist_version()
            if latest_version == "unknown" or latest_version == "Network error" then
                result.success = false
                result.message = "Failed to get latest OpenList version: " .. latest_version
            elseif latest_version == current_version then
                result.success = true
                result.message = "OpenList is already up to date (version: " .. current_version .. ")"
            else
                log_openlistui_operation("OPENLIST_UPDATE", "Updating from " .. current_version .. " to " .. latest_version .. " (" .. (use_lite and "lite" or "full") .. ")")
                local download_success, download_path = download_openlist(latest_version, use_lite)
                if download_success then
                    local install_success, install_message = install_openlist(download_path)
                    result.success = install_success
                    result.message = install_success and ("OpenList " .. (use_lite and "lite " or "") .. "updated successfully to version " .. latest_version) or ("Update failed: " .. (install_message or "Unknown error"))
                    -- Clean up downloaded file
                    sys.exec("rm -f '" .. download_path .. "'")
                else
                    result.success = false
                    result.message = "Failed to download OpenList update: " .. (download_path or "Unknown error")
                end
            end
        end
        

        
    else
        result.message = "Unknown component: " .. component
        log_openlistui_operation("COMPONENT_UPDATE", "Unknown component requested: " .. component)
    end
    
    log_openlistui_operation("COMPONENT_UPDATE", "Update result for " .. component .. ": " .. (result.success and "success" or "failed"))
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Save configuration action
function action_save_config()
    local target_arch = luci.http.formvalue("target_arch")
    local release_branch = luci.http.formvalue("release_branch") 
    local core_type = luci.http.formvalue("core_type")
    
    log_openlistui_operation("SAVE_CONFIG", "Saving configuration: arch=" .. (target_arch or "none") .. 
        ", branch=" .. (release_branch or "none") .. ", type=" .. (core_type or "none"))
    
    -- Save to UCI configuration
    if target_arch then
        uci:set("openlistui", "config", "target_arch", target_arch)
    end
    if release_branch then  
        uci:set("openlistui", "config", "release_branch", release_branch)
    end
    if core_type then
        uci:set("openlistui", "config", "core_type", core_type)
    end
    
    uci:commit("openlistui")
    
    local result = {
        success = true,
        message = "Configuration saved successfully"
    }
    
    http.prepare_content("application/json")
    http.write(json_encode(result))
end

-- Helper function to install OpenList if needed
function install_openlist_if_needed()
    log_openlistui_operation("INSTALL_CHECK", "Checking if OpenList installation is needed")
    
    -- Check if OpenList binary exists
    local openlist_binary = find_openlist_binary()
    if openlist_binary then
        log_openlistui_operation("INSTALL_CHECK", "OpenList binary found at: " .. openlist_binary)
        return true, "OpenList already installed"
    end
    
    log_openlistui_operation("INSTALL_OPENLIST", "OpenList not found, starting installation")
    
    -- Get latest version from GitHub
    local latest_version = get_latest_openlist_version()
    if not latest_version or latest_version == "unknown" then
        log_openlistui_operation("INSTALL_OPENLIST", "Failed to get latest OpenList version")
        return false, "Failed to get latest version information"
    end
    
    log_openlistui_operation("INSTALL_OPENLIST", "Latest OpenList version: " .. latest_version)
    
    -- Download and install
    local success, message = download_openlist(latest_version, true)
    if success then
        log_openlistui_operation("INSTALL_OPENLIST", "OpenList installation completed successfully")
        return true, "OpenList installed successfully"
    else
        log_openlistui_operation("INSTALL_OPENLIST", "OpenList installation failed: " .. (message or "unknown error"))
        return false, message or "Installation failed"
    end
end

-- Get current LuCI app version
function get_current_luci_version()
    local version_file = "/usr/lib/lua/luci/version-openlistui"
    if fs.access(version_file) then
        local content = fs.readfile(version_file)
        if content then
            -- Try to match PKG_VERSION first (from Makefile format)
            local version = content:match("PKG_VERSION=([^\n]+)")
            if version then
                return version:gsub('"', '')
            end
            -- Fallback to VERSION format
            version = content:match("VERSION=([^\n]+)")
            if version then
                return version:gsub('"', '')
            end
        end
    end
    
    -- Fallback: try to get from opkg
    local pkg_info = sys.exec("opkg list-installed | grep luci-app-openlistui | awk '{print $3}'")
    if pkg_info and pkg_info ~= "" then
        local clean_version = util.trim(pkg_info)
        if clean_version ~= "" then
            return clean_version
        end
    end
    
    -- Last fallback: try to get from control file
    local control_info = sys.exec("opkg info luci-app-openlistui 2>/dev/null | grep '^Version:' | cut -d' ' -f2")
    if control_info and control_info ~= "" then
        local clean_version = util.trim(control_info)
        if clean_version ~= "" then
            return clean_version
        end
    end
    
    return "unknown"
end

-- Get latest LuCI app version from GitHub
function get_latest_luci_version()
    log_openlistui_operation("LUCI_VERSION_CHECK", "Getting latest LuCI app version from GitHub")
    
    -- First try to get from cache
    local cache_key = "luci_latest_version"
    local cached_result = get_cached_response(cache_key)
    if cached_result then
        log_openlistui_operation("LUCI_VERSION_CACHE", "Using cached LuCI version: " .. cached_result)
        return cached_result
    end
    
    -- Try to get latest version from GitHub API
    local url = "https://api.github.com/repos/drfccv/luci-app-openlistui/releases/latest"
    local headers = '-H "Accept: application/vnd.github.v3+json" -H "User-Agent: OpenListUI/1.0"'
    local response = execute_curl_with_cache(url, cache_key, headers)
    
    if response and response ~= "" and not response:match("curl:") and response:match("tag_name") then
        local tag_name = response:match('"tag_name"%s*:%s*"([^"]+)"')
        if tag_name then
            -- Remove 'v' prefix if present to normalize version
            local clean_version = tag_name:gsub("^v", "")
            log_openlistui_operation("LUCI_VERSION_SUCCESS", "Found latest LuCI app version: " .. tag_name .. " (cleaned: " .. clean_version .. ")")
            -- Cache the successful result
            set_cached_response(cache_key, clean_version)
            return clean_version
        end
    end
    
    log_openlistui_operation("LUCI_VERSION_FAILED", "Failed to get latest LuCI app version")
    return "unknown"
end

-- Check for LuCI app updates
function action_check_luci_updates()
    local result = {}
    
    local current_version = get_current_luci_version()
    local latest_version = get_latest_luci_version()
    
    local update_available = false
    if current_version ~= "unknown" and latest_version ~= "unknown" and 
       current_version ~= latest_version then
        update_available = true
        log_openlistui_operation("LUCI_UPDATE_CHECK", "Update available: " .. current_version .. " -> " .. latest_version)
    else
        log_openlistui_operation("LUCI_UPDATE_CHECK", "No update needed or version check failed")
    end
    
    result.success = true
    result.current_version = current_version
    result.latest_version = latest_version
    result.update_available = update_available
    result.download_url = "https://github.com/drfccv/luci-app-openlistui/releases"
    
    log_openlistui_operation("LUCI_UPDATE_CHECK_RESULT", 
        string.format("Current: %s, Latest: %s, Update available: %s", 
            current_version, latest_version, tostring(update_available)))
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- Download and install LuCI app update
function action_download_luci_update()
    local result = {}
    
    local latest_version = get_latest_luci_version()
    if latest_version == "unknown" then
        log_openlistui_operation("LUCI_UPDATE_ERROR", "Failed to get latest version information")
        result.success = false
        result.message = "Unable to get latest version information"
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    local arch = get_system_arch()
    if not arch then
        log_openlistui_operation("LUCI_UPDATE_ERROR", "Unable to detect system architecture")
        result.success = false
        result.message = "Unable to detect system architecture"
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    local mapped_arch = map_arch_to_luci_ipk(arch)
    if not mapped_arch then
        log_openlistui_operation("LUCI_UPDATE_ERROR", "Unsupported architecture: " .. arch)
        result.success = false
        result.message = "Unsupported architecture: " .. arch
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    local version_tag = "v" .. latest_version
    local ipk_filename = string.format("luci-app-openlistui_v%s_%s.ipk", latest_version, mapped_arch)
    local download_url = string.format("https://github.com/drfccv/luci-app-openlistui/releases/download/%s/%s", 
        version_tag, ipk_filename)
    
    log_openlistui_operation("LUCI_UPDATE_DOWNLOAD", "Downloading LuCI update: " .. latest_version .. " (" .. mapped_arch .. ")")
    
    local temp_dir = "/tmp/luci-app-update"
    local temp_file = temp_dir .. "/" .. ipk_filename
    
    sys.exec("mkdir -p " .. temp_dir)
    
    local proxied_url = apply_proxy_to_url(download_url)
    local download_cmd = string.format("curl -L --connect-timeout 30 --max-time 300 -o '%s' '%s' 2>/dev/null", temp_file, proxied_url)
    local download_result = sys.call(download_cmd)
    
    if download_result ~= 0 then
        log_openlistui_operation("LUCI_UPDATE_ERROR", "Download failed with curl error code: " .. download_result)
        result.success = false
        result.message = "Failed to download update package (curl error: " .. download_result .. ")"
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    if not fs.access(temp_file) then
        log_openlistui_operation("LUCI_UPDATE_ERROR", "Downloaded file not found")
        result.success = false
        result.message = "Downloaded file not found"
        http.prepare_content("application/json")
        http.write_json(result)
        return
    end
    
    local file_stat = fs.stat(temp_file)
    if file_stat then
        if file_stat.size < 1000 then
            log_openlistui_operation("LUCI_UPDATE_ERROR", "Downloaded file too small, likely corrupted")
            result.success = false
            result.message = "Downloaded file appears to be corrupted (too small)"
            http.prepare_content("application/json")
            http.write_json(result)
            return
        end
    end
    
    local install_cmd = string.format("opkg install --force-reinstall '%s'", temp_file)
    local install_result = sys.call(install_cmd)
    
    if install_result == 0 then
        result.success = true
        result.message = "LuCI app updated successfully to version " .. latest_version
        result.new_version = latest_version
        
        sys.exec("rm -f " .. temp_file)
        
        local restart_result = sys.call("/etc/init.d/uhttpd restart")
        if restart_result ~= 0 then
            log_openlistui_operation("LUCI_UPDATE_WARNING", "uhttpd restart failed with code: " .. restart_result)
        end
        
        log_openlistui_operation("LUCI_UPDATE_SUCCESS", "LuCI app updated to version " .. latest_version)
    else
        log_openlistui_operation("LUCI_UPDATE_ERROR", "Package installation failed with opkg error code: " .. install_result)
        result.success = false
        result.message = "Failed to install update package"
        
        sys.exec("rm -f " .. temp_file)
    end
    
    http.prepare_content("application/json")
    http.write_json(result)
end

-- 传统LuCI模块使用module()函数自动导出所有全局函数，无需手动导出
