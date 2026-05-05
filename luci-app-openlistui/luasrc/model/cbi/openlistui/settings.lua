-- Copyright 2025 Drfccv
-- Licensed under the MIT License

local uci = require "luci.model.uci".cursor()
local fs = require "nixio.fs"
local sys = require "luci.sys"
local nixio = require "nixio"

m = Map("openlistui", translate("OpenList Settings"), translate("Configure OpenList services, storage, and application settings"))

-- OpenList Service Section
s = m:section(NamedSection, "main", "openlistui", translate("OpenList Service"))
s.addremove = false
s.anonymous = false

-- Network Configuration
port = s:option(Value, "port", translate("Listen Port"))
port.datatype = "port"
port.default = "5244"
port.placeholder = "5244"
port.description = translate("Port number for OpenList web interface (1024-65535)")

function port.validate(self, value)
    local port_num = tonumber(value)
    if not port_num or port_num < 1024 or port_num > 65535 then
        return nil, translate("Port must be between 1024 and 65535")
    end
    return value
end

data_dir = s:option(Value, "data_dir", translate("Data Directory"))
data_dir.default = "/etc/openlistui"
data_dir.placeholder = "/etc/openlistui"
data_dir.description = translate("Directory where OpenList stores its data and configuration")

function data_dir.validate(self, value)
    if not value or value == "" then
        return nil, translate("Data directory cannot be empty")
    end
    return value
end

cache_dir = s:option(Value, "cache_dir", translate("Cache Directory"))
cache_dir.default = "/tmp/openlistui"
cache_dir.placeholder = "/tmp/openlistui"
cache_dir.description = translate("Directory where OpenList stores temporary files and cache")

function cache_dir.validate(self, value)
    if not value or value == "" then
        return nil, translate("Cache directory cannot be empty")
    end
    return value
end

enable_https = s:option(Flag, "enable_https", translate("Enable SSL (HTTPS)"))
enable_https.default = "0"
enable_https.description = translate("Use HTTPS for secure connections")

https_port = s:option(Value, "https_port", translate("HTTPS Port"))
https_port.datatype = "port"
https_port.default = "5443"
https_port.placeholder = "5443"
https_port.description = translate("Port number for HTTPS connections (1024-65535)")
https_port:depends("enable_https", "1")

function https_port.validate(self, value)
    local port_num = tonumber(value)
    if not port_num or port_num < 1024 or port_num > 65535 then
        return nil, translate("Port must be between 1024 and 65535")
    end
    return value
end

cert_file = s:option(TextValue, "cert_file", translate("SSL Certificate"))
cert_file.rows = 10
cert_file.description = translate("Paste your SSL certificate content here (PEM format)")
cert_file:depends("enable_https", "1")

key_file = s:option(TextValue, "key_file", translate("SSL Private Key"))
key_file.rows = 10
key_file.description = translate("Paste your SSL private key content here (PEM format)")
key_file:depends("enable_https", "1")

force_https = s:option(Flag, "force_https", translate("Force HTTPS"))
force_https.default = "0"
force_https.description = translate("Force all connections to use HTTPS")
force_https:depends("enable_https", "1")

-- Custom write function for certificate file
function cert_file.write(self, section, value)
    if value and value ~= "" then
        local uci = require "luci.model.uci".cursor()
        local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
        local cert_path = data_dir .. "/data/cert.crt"
        
        -- Create data directory if it doesn't exist
        local sys = require "luci.sys"
        sys.exec("mkdir -p '" .. data_dir .. "/data'")
        
        -- Write certificate to file
        local fs = require "nixio.fs"
        fs.writefile(cert_path, value)
        
        -- Set proper permissions
        sys.exec("chmod 600 '" .. cert_path .. "'")
    end
    
    -- Don't save to UCI config
    return nil
end

-- Custom write function for private key file
function key_file.write(self, section, value)
    if value and value ~= "" then
        local uci = require "luci.model.uci".cursor()
        local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
        local key_path = data_dir .. "/data/key.key"
        
        -- Create data directory if it doesn't exist
        local sys = require "luci.sys"
        sys.exec("mkdir -p '" .. data_dir .. "/data'")
        
        -- Write private key to file
        local fs = require "nixio.fs"
        fs.writefile(key_path, value)
        
        -- Set proper permissions (more restrictive for private key)
        sys.exec("chmod 600 '" .. key_path .. "'")
    end
    
    -- Don't save to UCI config
    return nil
end

cors_enabled = s:option(Flag, "cors_enabled", translate("Allow External Access"))
cors_enabled.default = "0"
cors_enabled.description = translate("Allow access from external networks (Controls OpenWrt firewall rules for HTTP, FTP, SFTP and S3 ports based on config.json)")

-- Manage firewall rules for external access
-- Read ports from config.json
local function get_ports_from_config()
    local uci = require "luci.model.uci".cursor()
    local fs = require "nixio.fs"
    local json = require "luci.jsonc"
    
    local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
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
            local config = json.parse(content)
            if config then
                if config.scheme then
                    if config.scheme.http_port then
                        ports.http_port = tostring(config.scheme.http_port)
                    end
                    if config.scheme.https_port and config.scheme.https_port > 0 then
                        ports.https_port = tostring(config.scheme.https_port)
                    end
                end
                if config.ftp and config.ftp.listen then
                    local ftp_listen = config.ftp.listen
                    local ftp_port = ftp_listen:match(":(%d+)")
                    if ftp_port then
                        ports.ftp_port = ftp_port
                    end
                end
                if config.sftp and config.sftp.listen then
                    local sftp_listen = config.sftp.listen
                    local sftp_port = sftp_listen:match(":(%d+)")
                    if sftp_port then
                        ports.sftp_port = sftp_port
                    end
                end
                if config.s3 and config.s3.port then
                    ports.s3_port = tostring(config.s3.port)
                end
            end
        end
    end
    
    return ports
end

function cors_enabled.write(self, section, value)
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    
    -- Define the firewall rule name
    local rule_name = "openlist_external_access"
    
    -- Remove existing rule first
    uci:delete("firewall", rule_name)
    
    if value == "1" then
        -- Get ports from config.json
        local ports = get_ports_from_config()
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
    
    -- Call the default write function
    Flag.write(self, section, value)
end

auto_start = s:option(Flag, "auto_start", translate("Auto Start on Boot"))
auto_start.default = "0"
auto_start.description = translate("Automatically start OpenList service when system boots")

admin_password = s:option(Value, "admin_password", translate("Administrator Password"))
admin_password.password = true
admin_password.placeholder = translate("Enter new password to set")
admin_password.description = translate("Enter a new password to set for OpenList administrator. Password will not be saved in config file.")

function admin_password.write(self, section, value)
    if value and value ~= "" then
        -- Set password using OpenList command line
        local sys = require "luci.sys"
        local uci = require "luci.model.uci".cursor()
        
        -- Find OpenList binary path
        local openlist_path = ""
        local kernel_save_path = uci:get("openlistui", "integration", "kernel_save_path") or "/tmp/openlist"
        local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
        
        -- Try different paths to find openlist binary
        local possible_paths = {
            kernel_save_path .. "/openlist",
            "/usr/share/openlistui/openlist",
            "/usr/bin/openlist",
            "/usr/local/bin/openlist",
            "/opt/bin/openlist",
            "/etc/openlistui/openlist"
        }
        
        for _, path in ipairs(possible_paths) do
            if nixio.fs.access(path) then
                openlist_path = path
                break
            end
        end
        
        if openlist_path ~= "" then
            -- Execute password set command
            local cmd = string.format("cd '%s' && '%s' admin set '%s' 2>&1", data_dir, openlist_path, value)
            local result = sys.exec(cmd)
            
            -- Log the operation
            local log_msg = string.format("$(date): Password set via LuCI interface - Result: %s", result or "Success")
            sys.exec(string.format("echo '%s' >> /var/log/openlist.log", log_msg))
        else
            -- Log error if binary not found
            sys.exec("echo '$(date): Failed to set password - OpenList binary not found' >> /var/log/openlist.log")
        end
    end
    
    -- Always return nil to prevent saving password to config file
    return nil
end

function admin_password.cfgvalue(self, section)
    -- Always return empty string to keep field blank
    return ""
end



-- Application Settings Section
s3 = m:section(NamedSection, "integration", "openlistui", translate("Application Settings"))
s3.addremove = false
s3.anonymous = false

github_proxy = s3:option(Value, "github_proxy", translate("GitHub Proxy"))
github_proxy.placeholder = "https://ghfast.top"
github_proxy.description = translate("Optional. Enter proxy address to accelerate GitHub access. Example: https://ghfast.top")

github_token = s3:option(Value, "github_token", translate("GitHub Token"))
github_token.placeholder = "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
github_token.description = translate("Optional. Enter GitHub Personal Access Token to avoid API rate limits (60/hour → 5000/hour). Generate at: https://github.com/settings/tokens")
github_token.password = true

kernel_save_path = s3:option(Value, "kernel_save_path", translate("Kernel Save Location"))
kernel_save_path.default = "/tmp/openlist"
kernel_save_path.placeholder = "/tmp/openlist"
kernel_save_path.description = translate("Directory where OpenList core binaries are downloaded and stored")

function kernel_save_path.validate(self, value)
    if not value or value == "" then
        return nil, translate("Kernel save path cannot be empty")
    end
    return value
end

-- Update config.json with new settings
local function update_config_json_settings(data_dir, port, cache_dir, enable_https, https_port, force_https)
    local config_file = data_dir .. "/data/config.json"
    if fs.access(config_file) then
        -- Read current config
        local content = fs.readfile(config_file)
        if content then
            -- Update basic settings
            sys.call("sed -i 's/\"http_port\": [0-9]*/\"http_port\": " .. port .. "/g' '" .. config_file .. "'")
            sys.call("sed -i 's|\"temp_dir\": \"[^\"]*\"|\"temp_dir\": \"" .. cache_dir .. "\"|g' '" .. config_file .. "'")
            
            -- Update HTTPS settings
            if enable_https == "1" then
                local https_port_num = https_port or "5443"
                local force_https_bool = (force_https == "1") and "true" or "false"
                local cert_path = data_dir .. "/data/cert.crt"
                local key_path = data_dir .. "/data/key.key"
                
                -- Update HTTPS port
                sys.call("sed -i 's/\"https_port\": [0-9-]*/\"https_port\": " .. https_port_num .. "/g' '" .. config_file .. "'")
                
                -- Update force_https
                sys.call("sed -i 's/\"force_https\": [a-z]*/\"force_https\": " .. force_https_bool .. "/g' '" .. config_file .. "'")
                
                -- Update certificate paths
                sys.call("sed -i 's|\"cert_file\": \"[^\"]*\"|\"cert_file\": \"" .. cert_path .. "\"|g' '" .. config_file .. "'")
                sys.call("sed -i 's|\"key_file\": \"[^\"]*\"|\"key_file\": \"" .. key_path .. "\"|g' '" .. config_file .. "'")
            else
                -- Disable HTTPS
                sys.call("sed -i 's/\"https_port\": [0-9]*/\"https_port\": -1/g' '" .. config_file .. "'")
                sys.call("sed -i 's/\"force_https\": [a-z]*/\"force_https\": false/g' '" .. config_file .. "'")
                sys.call("sed -i 's|\"cert_file\": \"[^\"]*\"|\"cert_file\": \"\"|g' '" .. config_file .. "'")
                sys.call("sed -i 's|\"key_file\": \"[^\"]*\"|\"key_file\": \"\"|g' '" .. config_file .. "'")
            end
        end
    end
end

-- Add custom save logic to restart service if needed
function m.commit_handler(self)
    -- Call the default commit handler first
    if Map.commit_handler then
        Map.commit_handler(self)
    end
    
    -- Create necessary directories after saving configuration
    local uci = require "luci.model.uci".cursor()
    local data_dir = uci:get("openlistui", "main", "data_dir") or "/etc/openlistui"
    local cache_dir = uci:get("openlistui", "main", "cache_dir") or "/tmp/openlistui"
    local kernel_save_path = uci:get("openlistui", "integration", "kernel_save_path") or "/tmp/openlist"
    local port = uci:get("openlistui", "main", "port") or "5244"
    
    -- Create main data directory
    sys.call("mkdir -p '" .. data_dir .. "'")
    sys.call("chmod 755 '" .. data_dir .. "'")
    
    -- Create cache directory
    sys.call("mkdir -p '" .. cache_dir .. "'")
    sys.call("chmod 755 '" .. cache_dir .. "'")
    
    -- Create data subdirectory
    sys.call("mkdir -p '" .. data_dir .. "/data'")
    sys.call("chmod 755 '" .. data_dir .. "/data'")
    
    -- Create backup directory
    sys.call("mkdir -p '" .. data_dir .. "/backup'")
    sys.call("chmod 755 '" .. data_dir .. "/backup'")
    
    -- Create kernel save directory
    sys.call("mkdir -p '" .. kernel_save_path .. "'")
    sys.call("chmod 755 '" .. kernel_save_path .. "'")
    
    -- Get SSL settings
    local enable_https = uci:get("openlistui", "main", "enable_https") or "0"
    local https_port = uci:get("openlistui", "main", "https_port") or "5443"
    local force_https = uci:get("openlistui", "main", "force_https") or "0"
    
    -- Update config.json with new settings
    update_config_json_settings(data_dir, port, cache_dir, enable_https, https_port, force_https)
    
    -- Re-apply firewall rules if external access is enabled
    local cors_enabled = uci:get("openlistui", "main", "cors_enabled")
    if cors_enabled == "1" then
        local rule_name = "openlist_external_access"
        
        -- Remove existing rule first
        uci:delete("firewall", rule_name)
        
        -- Get updated ports from config.json
        local ports = get_ports_from_config()
        local dest_ports = ports.http_port .. " " .. ports.ftp_port .. " " .. ports.sftp_port .. " " .. ports.s3_port
        
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
    
    -- Only clear admin_password if it was actually set
    local admin_pass = uci:get("openlistui", "main", "admin_password")
    if admin_pass and admin_pass ~= "" then
        uci:delete("openlistui", "main", "admin_password")
        uci:commit("openlistui")
    end
    
    -- Check if OpenList service is running and restart it to apply new settings
    local running = sys.call("pgrep -f 'openlist' >/dev/null 2>&1") == 0
    if running then
        sys.call("sleep 1 && /etc/init.d/openlistui restart >/dev/null 2>&1 &")
    end
end

return m