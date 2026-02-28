#!/bin/sh

# PeDitXOS Tools - TORPlus Installer v36.0 (APK + Webtunnel Support)

echo ">>> Starting TORPlus installation (APK version)..."

LOG_FILE="/tmp/peditxos_torplus_log.txt"
DEBUG_LOG_FILE="/tmp/torplus_debug.log"

# Функция для проверки наличия команды
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Installing $1..."
        apk add "$2"
    fi
}

# --- Main TORPlus installation function ---
install_torplus() {
    echo "Updating APK repositories..."
    apk update

    echo "Installing required packages..."
    # Устанавливаем необходимые пакеты через APK
    apk add tor obfs4proxy curl ca-certificates
    apk add luci-compat luci-lib-ipkg 2>/dev/null || echo "Note: Some LuCI packages may not be available in APK"
    
    # Установка snowflake (webtunnel) - доступен в community репозитории
    echo "Adding community repository for snowflake..."
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
    apk update
    
    echo "Installing snowflake (webtunnel support)..."
    apk add snowflake-client
    
    echo "Creating TORPlus LuCI UI..."

    # Создаем необходимые директории
    mkdir -p /usr/lib/lua/luci/view/torplus
    mkdir -p /usr/lib/lua/luci/controller
    mkdir -p /etc/torplus

    # Проверка и создание UCI конфига
    if [ ! -f /etc/config/torplus ]; then
        echo "Creating UCI configuration for torplus..."
        cat > /etc/config/torplus << 'EOF'
config settings 'settings'
    option bridge_type 'custom'
    option custom_bridges ''
    option use_custom '1'
EOF
    fi
    
    # Убеждаемся что настройки существуют
    if ! uci -q get torplus.settings >/dev/null 2>&1; then
        uci set torplus.settings=torplus
        uci set torplus.settings.bridge_type='custom'
        uci set torplus.settings.custom_bridges=''
        uci set torplus.settings.use_custom='1'
        uci commit torplus
    fi

    # Пишем LuCI контроллер с поддержкой webtunnel
    cat > /usr/lib/lua/luci/controller/torplus.lua <<'EoL'
module("luci.controller.torplus", package.seeall)

function index()
    local fs = require "nixio.fs"
    if not fs.access("/etc/config/torplus") then
        return
    end
    
    entry({"admin", "services", "torplus"}, template("torplus/main"), _("TORPlus"), 92)
    entry({"admin", "services", "torplus_api"}, call("api_handler")).leaf = true
end

function api_handler()
    local http = require("luci.http")
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local nixio = require("nixio")
    local action = http.formvalue("action")
    local DEBUG_LOG_FILE = "/tmp/torplus_debug.log"

    if action == "status" then
        local running = sys.call("pgrep -f '/usr/bin/tor' >/dev/null 2>&1") == 0
        local ip = "N/A"
        local bridge = uci:get("torplus", "settings", "bridge_type") or "custom"
        local use_custom = uci:get("torplus", "settings", "use_custom") or "1"
        local custom_bridges = uci:get("torplus", "settings", "custom_bridges") or ""
        
        if running then
            for i = 1, 3 do
                ip = sys.exec("curl --socks5 127.0.0.1:9050 -m 5 -s http://ifconfig.me/ip 2>/dev/null")
                ip = ip:gsub("\n", "")
                if ip ~= "" and ip ~= "N/A" then
                    break
                end
                sys.call("sleep 2")
            end
        end

        http.prepare_content("application/json")
        http.write_json({
            running = running, 
            ip = ip, 
            bridge = bridge,
            use_custom = use_custom,
            custom_bridges = custom_bridges
        })
        
    elseif action == "toggle" then
        local running = sys.call("pgrep -f '/usr/bin/tor' >/dev/null 2>&1") == 0
        if running then
            sys.call("/etc/init.d/tor stop > " .. DEBUG_LOG_FILE .. " 2>&1")
        else
            sys.call("/etc/init.d/tor start > " .. DEBUG_LOG_FILE .. " 2>&1")
        end
        
        http.prepare_content("application/json")
        http.write_json({success = true})
        
    elseif action == "save_bridge" then
        local bridge_type = http.formvalue("bridge_type") or "custom"
        local custom_bridges = http.formvalue("custom_bridges") or ""
        local use_custom = http.formvalue("use_custom") or "1"
        custom_bridges = custom_bridges:gsub("%+", " ")
        
        sys.call("echo '--- Debug Log Started: $(date) ---' > " .. DEBUG_LOG_FILE)
        sys.call("echo 'Action: save_bridge, Bridge Type: " .. bridge_type .. "' >> " .. DEBUG_LOG_FILE)
        sys.call("echo 'Use Custom: " .. use_custom .. "' >> " .. DEBUG_LOG_FILE)
        
        -- Сохраняем настройки в UCI
        uci:set("torplus", "settings", "bridge_type", bridge_type)
        uci:set("torplus", "settings", "custom_bridges", custom_bridges)
        uci:set("torplus", "settings", "use_custom", use_custom)
        uci:commit("torplus")
        
        sys.call("echo 'UCI settings saved.' >> " .. DEBUG_LOG_FILE)

        -- Строим конфиг torrc с поддержкой webtunnel
        local torrc_content = "SocksPort 9050\n"
        local plugins_added = {}
        
        -- Проверяем пути для бинарников в Alpine
        local obfs4_path = "/usr/bin/obfs4proxy"
        local snowflake_path = "/usr/bin/snowflake-client"
        local meek_path = "/usr/bin/meek-client"
        
        if use_custom == "1" and custom_bridges ~= "" then
            torrc_content = torrc_content .. "UseBridges 1\n"
            
            -- Определяем нужные плагины
            for bridge_line in custom_bridges:gmatch("[^\r\n]+") do
                local clean_line = bridge_line:gsub("^%s*(.-)%s*$", "%1")
                if clean_line ~= "" and not clean_line:match("^#") then
                    if clean_line:match("^%s*obfs4") then
                        plugins_added["obfs4"] = true
                    elseif clean_line:match("^%s*webtunnel") then
                        plugins_added["webtunnel"] = true
                    elseif clean_line:match("^%s*meek") then
                        plugins_added["meek"] = true
                    end
                end
            end
            
            -- Добавляем плагины
            if plugins_added["obfs4"] and nixio.fs.access(obfs4_path) then
                torrc_content = torrc_content .. "ClientTransportPlugin obfs4 exec " .. obfs4_path .. "\n"
            end
            
            if plugins_added["webtunnel"] then
                if nixio.fs.access(snowflake_path) then
                    torrc_content = torrc_content .. "ClientTransportPlugin webtunnel exec " .. snowflake_path .. "\n"
                else
                    torrc_content = torrc_content .. "# WARNING: snowflake-client not found\n"
                    torrc_content = torrc_content .. "# Run: apk add snowflake-client\n"
                end
            end
            
            if plugins_added["meek"] and nixio.fs.access(meek_path) then
                torrc_content = torrc_content .. "ClientTransportPlugin meek exec " .. meek_path .. "\n"
            end
            
            -- Добавляем мосты
            for bridge_line in custom_bridges:gmatch("[^\r\n]+") do
                local clean_line = bridge_line:gsub("^%s*(.-)%s*$", "%1")
                if clean_line ~= "" and not clean_line:match("^#") then
                    torrc_content = torrc_content .. "Bridge " .. clean_line .. "\n"
                end
            end
            
        else
            torrc_content = torrc_content .. "UseBridges 0\n"
        end

        -- Записываем конфиг
        local f = io.open("/etc/tor/torrc", "w")
        if f then
            f:write(torrc_content)
            f:close()
        end
        
        sys.call("echo 'torrc file written.' >> " .. DEBUG_LOG_FILE)
        sys.call("/etc/init.d/tor restart >> " .. DEBUG_LOG_FILE .. " 2>&1")
        sys.call("echo 'Tor service restarted.' >> " .. DEBUG_LOG_FILE)
        
        http.prepare_content("application/json")
        http.write_json({success = true})
        
    elseif action == "get_debug_log" then
        local content = ""
        local f = io.open(DEBUG_LOG_FILE, "r")
        if f then 
            content = f:read("*a") 
            f:close() 
        end
        http.prepare_content("application/json")
        http.write_json({log = content})
        
    elseif action == "check_snowflake" then
        -- Проверяем установку snowflake
        local has_snowflake = false
        local path = ""
        local version = ""
        
        -- Проверяем через which
        local handle = io.popen("which snowflake-client 2>/dev/null")
        local which_output = handle:read("*l")
        handle:close()
        
        if which_output and which_output ~= "" then
            has_snowflake = true
            path = which_output
        end
        
        -- Проверяем APK статус
        local apk_handle = io.popen("apk list -I | grep snowflake-client 2>/dev/null")
        local apk_status = apk_handle:read("*l")
        apk_handle:close()
        
        -- Получаем версию
        if has_snowflake and path ~= "" then
            local handle = io.popen(path .. " --version 2>&1 | head -1 || echo 'unknown'")
            version = handle:read("*l") or "unknown"
            handle:close()
        end
        
        http.prepare_content("application/json")
        http.write_json({
            installed = has_snowflake,
            path = path,
            version = version,
            apk = apk_status ~= nil
        })
        
    elseif action == "install_snowflake" then
        sys.call("echo 'Starting snowflake installation via APK...' >> " .. DEBUG_LOG_FILE)
        local result = sys.exec("apk add snowflake-client 2>&1")
        local success = sys.call("which snowflake-client >/dev/null 2>&1") == 0
        
        http.prepare_content("application/json")
        http.write_json({
            success = success,
            output = result
        })
    end
end
EoL
    
    # Пишем LuCI view файл с поддержкой webtunnel
    cat > /usr/lib/lua/luci/view/torplus/main.htm <<'EoL'
<%+header%>
<style>
.torplus-container{
    max-width: 700px;
    margin: 40px auto;
    padding: 24px;
    background-color: rgba(30, 30, 30, 0.9);
    backdrop-filter: blur(10px);
    border: 1px solid rgba(255, 255, 255, 0.2);
    box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.1);
    border-radius: 12px;
    font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Oxygen,Ubuntu,Cantarell,"Fira Sans","Droid Sans","Helvetica Neue",sans-serif;
    color: #f0f0f0;
}
h2{
    text-align: center;
    color: #fff;
    margin-bottom: 24px;
}
.torplus-row{
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 0;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}
.torplus-row:last-child{
    border-bottom: none;
}
.torplus-label{
    font-weight: 600;
    color: #ccc;
    min-width: 180px;
}
.torplus-value{
    font-weight: 700;
    color: #fff;
    flex-grow: 1;
}
.torplus-status-indicator{
    display: inline-block;
    width: 12px;
    height: 12px;
    border-radius: 50%;
    margin-right: 8px;
}
.status-connected{
    background-color: #28a745;
}
.status-disconnected{
    background-color: #dc3545;
}
.torplus-btn-group{
    display: flex;
    justify-content: center;
    gap: 16px;
    margin-top: 24px;
}
.torplus-btn{
    padding: 10px 24px;
    font-size: 16px;
    font-weight: 600;
    border: none;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 0.2s ease, transform 0.1s ease;
    background-color: rgba(255, 255, 255, 0.1);
    color: #fff;
}
.torplus-btn:hover{
    transform: translateY(-2px);
    background-color: rgba(255, 255, 255, 0.2);
}
.btn-connect{
    background-color: #28a745;
    color: white;
}
.btn-connect.disabled{
    background-color: #555;
    cursor: not-allowed;
}
.btn-disconnect{
    background-color: #dc3545;
    color: white;
}
.btn-disconnect:hover{
    background-color: #c82333;
}
.bridge-settings{
    margin-top: 24px;
    padding-top: 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
}
.bridge-settings label{
    display: block;
    font-weight: 600;
    color: #ccc;
    margin-bottom: 8px;
}
.bridge-type-selector{
    display: flex;
    gap: 10px;
    margin-bottom: 15px;
}
.bridge-type-btn {
    padding: 10px 15px;
    background-color: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.2);
    color: #fff;
    border-radius: 8px;
    cursor: pointer;
    font-weight: 600;
    transition: all 0.2s ease;
    flex: 1;
    text-align: center;
}
.bridge-type-btn:hover {
    background-color: rgba(255, 255, 255, 0.2);
}
.bridge-type-btn.selected {
    background-color: #007bff;
    border-color: #007bff;
    color: #fff;
    transform: scale(1.05);
}
.snowflake-info {
    background: rgba(0, 123, 255, 0.1);
    border-left: 4px solid #007bff;
    padding: 10px;
    margin-bottom: 15px;
    border-radius: 4px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}
.snowflake-info .status {
    font-weight: bold;
}
.snowflake-info .status.installed {
    color: #28a745;
}
.snowflake-info .status.not-installed {
    color: #dc3545;
}
.snowflake-info button {
    padding: 5px 10px;
    background: #28a745;
    color: white;
    border: none;
    border-radius: 4px;
    cursor: pointer;
}
.custom-bridges-section {
    margin-top: 20px;
    padding: 15px;
    background-color: rgba(0, 0, 0, 0.2);
    border-radius: 8px;
    border: 1px solid rgba(255, 255, 255, 0.1);
}
.custom-bridges-textarea {
    width: 100%;
    min-height: 150px;
    background-color: rgba(0, 0, 0, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 6px;
    color: #fff;
    padding: 10px;
    font-family: monospace;
    font-size: 12px;
    resize: vertical;
}
.bridge-examples {
    margin-top: 10px;
    font-size: 11px;
    color: #aaa;
    font-family: monospace;
}
.bridge-examples code {
    display: block;
    background: rgba(0, 0, 0, 0.3);
    padding: 5px;
    border-radius: 3px;
    margin: 5px 0;
    white-space: pre-wrap;
    word-break: break-all;
}
.save-bridge-btn {
    margin-top: 15px;
    padding: 10px 20px;
    background-color: #28a745;
    color: white;
    border: none;
    border-radius: 6px;
    cursor: pointer;
    font-weight: bold;
    width: 100%;
}
.save-bridge-btn:hover {
    background-color: #218838;
}
.debug-log-container {
    margin-top: 30px;
    padding: 15px;
    background-color: rgba(0, 0, 0, 0.3);
    border-radius: 8px;
}
.debug-log-container h3 {
    margin-top: 0;
    color: #fff;
}
#log-output {
    background-color: #000;
    color: #00ff00;
    padding: 10px;
    border-radius: 4px;
    font-family: monospace;
    font-size: 12px;
    white-space: pre-wrap;
    max-height: 200px;
    overflow-y: auto;
    border: 1px solid #333;
}
.snowflake-details {
    font-size: 11px;
    color: #aaa;
    margin-top: 5px;
}
.apk-badge {
    background: #4a6da7;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 10px;
    margin-left: 5px;
}
</style>

<div class="torplus-container">
    <h2>TORPlus Manager <span class="apk-badge">APK</span></h2>

    <div class="torplus-row">
        <span class="torplus-label">Service Status:</span>
        <span class="torplus-value">
            <span id="statusIndicator" class="torplus-status-indicator status-disconnected"></span>
            <span id="statusText">...</span>
        </span>
    </div>
    <div class="torplus-row">
        <span class="torplus-label">Outgoing IP:</span>
        <span id="ipText" class="torplus-value">...</span>
    </div>
    <div class="torplus-row">
        <span class="torplus-label">Bridge Mode:</span>
        <span id="bridgeModeText" class="torplus-value">Custom Bridges</span>
    </div>
    
    <div class="torplus-btn-group">
        <button id="connectBtn" class="torplus-btn btn-connect">Start Tor</button>
        <button id="disconnectBtn" class="torplus-btn btn-disconnect" style="display:none;">Stop Tor</button>
    </div>

    <div class="bridge-settings">
        <h3>Bridge Configuration</h3>
        
        <div id="snowflakeInfo" class="snowflake-info">
            <div>
                <strong>Webtunnel Support (Snowflake):</strong>
                <span id="snowflakeStatus" class="status not-installed">Checking...</span>
                <div id="snowflakeDetails" class="snowflake-details"></div>
            </div>
            <button id="installSnowflakeBtn">Install via APK</button>
        </div>
        
        <div class="bridge-type-selector">
            <button class="bridge-type-btn" data-bridge-type="custom">Custom Bridges</button>
            <button class="bridge-type-btn" data-bridge-type="none">No Bridges</button>
        </div>
        
        <div class="custom-bridges-section">
            <label>Custom Bridges (one per line):</label>
            <textarea id="customBridgesText" class="custom-bridges-textarea" 
                      placeholder="Supported formats:&#10;&#10;obfs4 1.2.3.4:1234 cert=ABCDEF iat-mode=0&#10;webtunnel [2001:db8::1]:443 FINGERPRINT url=https://example.com/ ver=0.0.3&#10;meek 0.0.2.0:2 url=https://meek.azureedge.net/ front=ajax.aspnetcdn.com"></textarea>
            
            <div class="bridge-examples">
                <strong>Examples:</strong>
                <code>obfs4 185.220.101.204:443 8FB9F4319E89E5C6223052AA525A192AFBC85D55 cert=GGGS1TX4R81m3r0HBl79wKy1OtPPNR2CZUIrHjkRg65Vc2VR8fOyo64f9kmT1UAFG7j0HQ iat-mode=0</code>
                <code>webtunnel [2001:db8:adeb:7e0f:5140:7cd5:28b1:4503]:443 32F772D0970C2849B2B5BF9F0EC9D3F878DAEA43 url=https://files.bitrot.cz/Bho2k74VTFX6Bwr2XJG5V8gLhZEKgRQ5 ver=0.0.3</code>
                
                <div style="margin-top: 10px;">
                    Get bridges from: <a href="https://bridges.torproject.org/" target="_blank" style="color: #4dabf7;">bridges.torproject.org</a>
                </div>
            </div>
        </div>
        
        <button id="saveBridgeBtn" class="save-bridge-btn">Save & Apply Bridge Settings</button>
    </div>

    <div class="debug-log-container">
        <h3>Debug Log</h3>
        <pre id="log-output">Waiting for an action...</pre>
    </div>
</div>

<script type="text/javascript">
(function() {
    const connectBtn = document.getElementById('connectBtn');
    const disconnectBtn = document.getElementById('disconnectBtn');
    const statusText = document.getElementById('statusText');
    const statusIndicator = document.getElementById('statusIndicator');
    const ipText = document.getElementById('ipText');
    const bridgeModeText = document.getElementById('bridgeModeText');
    const customBridgesText = document.getElementById('customBridgesText');
    const saveBridgeBtn = document.getElementById('saveBridgeBtn');
    const bridgeTypeButtons = document.querySelectorAll('.bridge-type-btn');
    const snowflakeInfo = document.getElementById('snowflakeInfo');
    const snowflakeStatus = document.getElementById('snowflakeStatus');
    const snowflakeDetails = document.getElementById('snowflakeDetails');
    const installSnowflakeBtn = document.getElementById('installSnowflakeBtn');
    
    let currentSettings = {
        bridge: 'custom',
        use_custom: '1',
        custom_bridges: ''
    };
    
    let isApplying = false;

    function checkSnowflake() {
        XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=check_snowflake', null, function(x, data) {
            if (data) {
                if (data.installed) {
                    snowflakeStatus.textContent = 'Installed (APK)';
                    snowflakeStatus.className = 'status installed';
                    installSnowflakeBtn.style.display = 'none';
                    
                    let details = '';
                    if (data.path) details += 'Path: ' + data.path + '\n';
                    if (data.version) details += 'Version: ' + data.version;
                    snowflakeDetails.textContent = details;
                } else {
                    snowflakeStatus.textContent = 'Not installed';
                    snowflakeStatus.className = 'status not-installed';
                    installSnowflakeBtn.style.display = 'inline-block';
                    snowflakeDetails.textContent = 'Run: apk add snowflake-client';
                }
            }
        });
    }

    function updateUIFromSettings() {
        bridgeModeText.innerText = currentSettings.bridge === 'none' ? 'Direct Connection' : 'Custom Bridges';
        
        bridgeTypeButtons.forEach(btn => {
            btn.classList.remove('selected');
            if (btn.dataset.bridgeType === currentSettings.bridge) {
                btn.classList.add('selected');
            }
        });
        
        customBridgesText.value = currentSettings.custom_bridges || '';
        
        if (currentSettings.bridge === 'none') {
            customBridgesText.disabled = true;
            customBridgesText.placeholder = 'Bridges disabled (direct connection)';
        } else {
            customBridgesText.disabled = false;
            customBridgesText.placeholder = 'Paste your bridges here...';
        }
    }

    function updateConnectionUI(running, ip) {
        statusText.innerText = running ? 'Connected' : 'Disconnected';
        statusIndicator.className = 'torplus-status-indicator ' + (running ? 'status-connected' : 'status-disconnected');
        ipText.innerText = running ? (ip?.trim() || 'N/A') : 'N/A';
        
        connectBtn.style.display = running ? 'none' : 'inline-block';
        disconnectBtn.style.display = running ? 'inline-block' : 'none';

        if (!isApplying) {
            connectBtn.classList.remove('disabled');
            connectBtn.innerText = 'Start Tor';
            disconnectBtn.classList.remove('disabled');
            disconnectBtn.innerText = 'Stop Tor';
        }
    }

    function toggleService() {
        isApplying = true;
        if (connectBtn.style.display !== 'none') {
            connectBtn.classList.add('disabled');
            connectBtn.innerText = 'Starting...';
        } else {
            disconnectBtn.classList.add('disabled');
            disconnectBtn.innerText = 'Stopping...';
        }
        
        XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=toggle', null, function(x, data) {
            isApplying = false;
        });
    }

    function saveBridgeSettings() {
        const selectedBtn = document.querySelector('.bridge-type-btn.selected');
        const bridgeType = selectedBtn ? selectedBtn.dataset.bridgeType : 'custom';
        const customBridges = customBridgesText.value.trim();
        
        if (bridgeType !== 'none' && customBridges === '') {
            alert('Please enter bridges or select "No Bridges"');
            return;
        }
        
        saveBridgeBtn.classList.add('disabled');
        saveBridgeBtn.innerText = 'Applying...';
        
        const params = new URLSearchParams({
            action: 'save_bridge',
            bridge_type: bridgeType,
            use_custom: '1',
            custom_bridges: bridgeType === 'none' ? '' : customBridges
        });
        
        XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?' + params.toString(), null, function(x, data) {
            saveBridgeBtn.classList.remove('disabled');
            saveBridgeBtn.innerText = 'Save & Apply Bridge Settings';
            
            if (data && data.success) {
                alert('Settings applied! Tor is restarting...');
                setTimeout(loadStatus, 3000);
            } else {
                alert('Failed to apply settings.');
            }
        });
    }

    function loadStatus() {
        XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=status', null, function(x, st) {
            if (!st) return;
            
            currentSettings.bridge = st.bridge || 'custom';
            currentSettings.use_custom = st.use_custom || '1';
            currentSettings.custom_bridges = st.custom_bridges || '';
            
            updateUIFromSettings();
            updateConnectionUI(st.running, st.ip);
        });
    }

    function installSnowflake() {
        if (confirm('Install snowflake-client via APK?\nThis will download and install the package.')) {
            installSnowflakeBtn.classList.add('disabled');
            installSnowflakeBtn.innerText = 'Installing...';
            
            XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=install_snowflake', 
                null, 
                function(x, data) {
                    installSnowflakeBtn.classList.remove('disabled');
                    installSnowflakeBtn.innerText = 'Install via APK';
                    
                    if (data && data.success) {
                        alert('Snowflake installed successfully via APK!');
                        checkSnowflake();
                        setTimeout(loadStatus, 2000);
                    } else {
                        alert('Installation failed:\n' + (data.output || 'Unknown error'));
                    }
                }
            );
        }
    }

    // Event Listeners
    connectBtn.addEventListener('click', toggleService);
    disconnectBtn.addEventListener('click', toggleService);
    
    bridgeTypeButtons.forEach(btn => {
        btn.addEventListener('click', function() {
            bridgeTypeButtons.forEach(b => b.classList.remove('selected'));
            this.classList.add('selected');
            
            const type = this.dataset.bridgeType;
            if (type === 'custom') {
                customBridgesText.disabled = false;
                customBridgesText.placeholder = 'Paste bridges (obfs4, webtunnel, meek)...';
            } else if (type === 'none') {
                customBridgesText.disabled = true;
                customBridgesText.placeholder = 'Bridges disabled (direct connection)';
                customBridgesText.value = '';
            }
        });
    });
    
    saveBridgeBtn.addEventListener('click', saveBridgeSettings);
    installSnowflakeBtn.addEventListener('click', installSnowflake);

    // Initial load
    loadStatus();
    checkSnowflake();
    
    XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=get_debug_log', null, function(x, data) {
        if (data && data.log) {
            document.getElementById('log-output').textContent = data.log;
        }
    });

    // Background polling
    XHR.poll(5, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=status', null, function(x, st) {
        if (st) {
            currentSettings.bridge = st.bridge || 'custom';
            currentSettings.use_custom = st.use_custom || '1';
            currentSettings.custom_bridges = st.custom_bridges || '';
            
            updateUIFromSettings();
            updateConnectionUI(st.running, st.ip);
        }
    });

    XHR.poll(30, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=check_snowflake', null, function(x, data) {
        if (data) {
            checkSnowflake();
        }
    });

    XHR.poll(2, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=get_debug_log', null, function(x, data) {
        if (data && data.log) {
            const logOutput = document.getElementById('log-output');
            logOutput.textContent = data.log;
        }
    });
})();
</script>
<%+footer%>
EoL

    # Удаляем старые файлы
    rm -f /usr/lib/lua/luci/model/cbi/torplus_manager.lua 2>/dev/null
    rm -f /usr/lib/lua/luci/view/torplus_status_section.htm 2>/dev/null
    
    # Создаем debug лог
    echo "TORPlus APK Edition installation started at $(date)" > "$DEBUG_LOG_FILE"

    # Пишем начальный torrc
    cat > /etc/tor/torrc << 'EOF'
SocksPort 9050
UseBridges 1

# Client transport plugins
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ClientTransportPlugin webtunnel exec /usr/bin/snowflake-client

# Example bridges (get fresh ones from https://bridges.torproject.org/)
EOF
    
    # Включаем и запускаем Tor
    if [ -f /etc/init.d/tor ]; then
        /etc/init.d/tor enable
        /etc/init.d/tor restart
    else
        echo "Warning: Tor init script not found, starting manually"
        tor --runasdaemon 1
    fi
    
    # Создаем скрипт проверки для APK
    cat > /usr/bin/check-torplus.sh << 'EOF'
#!/bin/sh
echo "=== TORPlus APK Status ==="
echo ""
echo "Installed packages:"
apk list -I | grep -E "tor|obfs4|snowflake|meek"
echo ""
echo "Tor status:"
if pgrep -f '/usr/bin/tor' >/dev/null 2>&1; then
    echo "Tor: RUNNING"
    echo "IP: $(curl --socks5 127.0.0.1:9050 -s http://ifconfig.me/ip 2>/dev/null || echo 'N/A')"
else
    echo "Tor: STOPPED"
fi
echo ""
echo "Snowflake status:"
if command -v snowflake-client >/dev/null 2>&1; then
    echo "Snowflake: INSTALLED"
    snowflake-client --version 2>&1 | head -1
else
    echo "Snowflake: NOT INSTALLED"
fi
EOF
    chmod +x /usr/bin/check-torplus.sh

    echo "TORPlus APK installation completed successfully."
}

# Запускаем установку
install_torplus

# Перезагружаем LuCI
rm -rf /tmp/luci-* 2>/dev/null
rm -f /var/run/luci-indexcache 2>/dev/null

if [ -f /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart 2>/dev/null
fi

cat << "EOM"

================================================
TORPlus with Webtunnel Support (APK Version) Installed!

Features:
✓ APK package manager support
✓ Webtunnel bridges via snowflake-client
✓ obfs4 and meek support
✓ Persistent installation (not just in RAM)

Commands:
  Install packages:  apk add snowflake-client obfs4proxy
  Check status:      /usr/bin/check-torplus.sh
  View logs:         tail -f /var/log/tor/log

Get bridges: https://bridges.torproject.org/

Access: Services → TORPlus in LuCI
SOCKS5: 127.0.0.1:9050
================================================
EOM
