#!/bin/sh

# PeDitXOS Tools - TORPlus Installer (Webtunnel Edition)

echo ">>> Starting TORPlus installation..."
LOG_FILE="/tmp/torplus_install.log"
DEBUG_LOG_FILE="/tmp/torplus_debug.log"

# --- Main TORPlus installation function ---
install_torplus() {
    echo "Installing required packages..."
    opkg update
    
    echo "Installing Tor and dependencies..."
    opkg install tor ca-certificates curl coreutils-base64
    
    echo "Installing Snowflake (includes webtunnel support)..."
    # Пробуем установить snowflake (лучший вариант для webtunnel)
    if opkg list | grep -q snowflake; then
        opkg install snowflake-proxy
        WEBTUNNEL_CLIENT="/usr/bin/snowflake-client"
    else
        echo "Snowflake not in repository. Installing obfs4proxy as fallback..."
        opkg install obfs4proxy
        WEBTUNNEL_CLIENT="/usr/bin/obfs4proxy"
    fi
    
    echo "Installing LuCI dependencies..."
    opkg install luci-base luci-compat luci-lib-ipkg luci-lib-nixio
    
    echo "Creating TORPlus LuCI UI..."

    # Ensure the directory exists
    mkdir -p /usr/lib/lua/luci/view/torplus
    
    # Create UCI config
    if [ ! -f /etc/config/torplus ]; then
        echo "Creating UCI configuration for torplus..."
        cat > /etc/config/torplus << 'EOF'
config settings 'settings'
    option bridge_type 'webtunnel'
    option custom_bridges ''
    option use_custom '1'
EOF
    fi
    
    # Ensure settings exist
    if ! uci -q get torplus.settings >/dev/null 2>&1; then
        uci set torplus.settings=torplus
        uci set torplus.settings.bridge_type='webtunnel'
        uci set torplus.settings.custom_bridges=''
        uci set torplus.settings.use_custom='1'
        uci commit torplus
    fi

    # Write the LuCI controller file
    mkdir -p /usr/lib/lua/luci/controller
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
        local running = sys.call("pgrep -f '/usr/sbin/tor' >/dev/null 2>&1") == 0
        local ip = "N/A"
        local bridge = uci:get("torplus", "settings", "bridge_type") or "webtunnel"
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
        local running = sys.call("pgrep -f '/usr/sbin/tor' >/dev/null 2>&1") == 0
        if running then
            sys.call("/etc/init.d/tor stop > " .. DEBUG_LOG_FILE .. " 2>&1")
        else
            sys.call("/etc/init.d/tor start > " .. DEBUG_LOG_FILE .. " 2>&1")
        end
        
        http.prepare_content("application/json")
        http.write_json({success = true})
        
    elseif action == "save_bridge" then
        local bridge_type = http.formvalue("bridge_type") or "webtunnel"
        local custom_bridges = http.formvalue("custom_bridges") or ""
        local use_custom = http.formvalue("use_custom") or "1"
        
        sys.call("echo '--- Debug Log Started: $(date) ---' > " .. DEBUG_LOG_FILE)
        sys.call("echo 'Action: save_bridge, Bridge Type: " .. bridge_type .. "' >> " .. DEBUG_LOG_FILE)
        
        -- Сохраняем настройки
        uci:set("torplus", "settings", "bridge_type", bridge_type)
        uci:set("torplus", "settings", "custom_bridges", custom_bridges)
        uci:set("torplus", "settings", "use_custom", use_custom)
        uci:commit("torplus")
        
        sys.call("echo 'UCI settings saved.' >> " .. DEBUG_LOG_FILE)

        -- Строим конфиг torrc с поддержкой webtunnel
        local torrc_content = "SocksPort 9050\n"
        
        if use_custom == "1" and custom_bridges ~= "" then
            -- Используем кастомные мосты (в основном webtunnel)
            torrc_content = torrc_content .. "UseBridges 1\n"
            
            -- Проверяем наличие snowflake для webtunnel
            local has_snowflake = nixio.fs.access("/usr/bin/snowflake-client")
            local has_obfs4 = nixio.fs.access("/usr/bin/obfs4proxy")
            
            -- Определяем, какие типы мостов есть
            local has_webtunnel = false
            local has_obfs4_bridge = false
            
            for bridge_line in custom_bridges:gmatch("[^\r\n]+") do
                local clean_line = bridge_line:gsub("^%s*(.-)%s*$", "%1")
                if clean_line ~= "" and not clean_line:match("^#") then
                    if clean_line:match("^%s*webtunnel") then
                        has_webtunnel = true
                    elseif clean_line:match("^%s*obfs4") then
                        has_obfs4_bridge = true
                    end
                end
            end
            
            -- Добавляем нужные плагины
            if has_webtunnel and has_snowflake then
                torrc_content = torrc_content .. "ClientTransportPlugin webtunnel exec /usr/bin/snowflake-client\n"
            elseif has_webtunnel then
                torrc_content = torrc_content .. "# WARNING: snowflake-client not found for webtunnel support\n"
                torrc_content = torrc_content .. "# Install snowflake-proxy package\n"
            end
            
            if has_obfs4_bridge and has_obfs4 then
                torrc_content = torrc_content .. "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy\n"
            end
            
            -- Добавляем сами мосты
            for bridge_line in custom_bridges:gmatch("[^\r\n]+") do
                local clean_line = bridge_line:gsub("^%s*(.-)%s*$", "%1")
                if clean_line ~= "" and not clean_line:match("^#") then
                    torrc_content = torrc_content .. "Bridge " .. clean_line .. "\n"
                end
            end
            
        else
            -- Стандартные настройки (без фиктивных мостов)
            if bridge_type == "webtunnel" then
                torrc_content = torrc_content .. "UseBridges 1\n"
                if nixio.fs.access("/usr/bin/snowflake-client") then
                    torrc_content = torrc_content .. "ClientTransportPlugin webtunnel exec /usr/bin/snowflake-client\n"
                else
                    torrc_content = torrc_content .. "# Install snowflake-proxy for webtunnel support\n"
                end
                torrc_content = torrc_content .. "# Add webtunnel bridges in custom section\n"
            elseif bridge_type == "obfs4" then
                torrc_content = torrc_content .. "UseBridges 1\n"
                if nixio.fs.access("/usr/bin/obfs4proxy") then
                    torrc_content = torrc_content .. "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy\n"
                end
                torrc_content = torrc_content .. "# Add obfs4 bridges in custom section\n"
            else
                torrc_content = torrc_content .. "UseBridges 0\n"
            end
        end

        -- Пишем конфиг
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
    end
end
EoL
    
    # Write the LuCI view file с акцентом на webtunnel
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
    margin-bottom: 20px;
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
.custom-bridges-section {
    margin-top: 20px;
    padding: 15px;
    background-color: rgba(0, 0, 0, 0.2);
    border-radius: 8px;
    border: 1px solid rgba(255, 255, 255, 0.1);
}
.bridge-info {
    background: rgba(0, 123, 255, 0.1);
    border-left: 4px solid #007bff;
    padding: 10px;
    margin-bottom: 15px;
    border-radius: 4px;
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
</style>

<div class="torplus-container">
    <h2>TORPlus Manager (Webtunnel Edition)</h2>

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
        <span id="bridgeModeText" class="torplus-value">...</span>
    </div>
    
    <div class="torplus-btn-group">
        <button id="connectBtn" class="torplus-btn btn-connect">Start Tor</button>
        <button id="disconnectBtn" class="torplus-btn btn-disconnect" style="display:none;">Stop Tor</button>
    </div>

    <div class="bridge-settings">
        <h3>Bridge Configuration</h3>
        
        <div class="bridge-info">
            <strong>Webtunnel Recommended:</strong> Webtunnel bridges work better in restrictive networks.
            Get bridges from: <a href="https://bridges.torproject.org/" target="_blank" style="color: #4dabf7;">bridges.torproject.org</a>
        </div>
        
        <div class="bridge-type-selector">
            <button class="bridge-type-btn" data-bridge-type="webtunnel">Webtunnel</button>
            <button class="bridge-type-btn" data-bridge-type="obfs4">obfs4</button>
            <button class="bridge-type-btn" data-bridge-type="none">No Bridges</button>
        </div>
        
        <div class="custom-bridges-section">
            <label>Custom Bridges (one per line):</label>
            <textarea id="customBridgesText" class="custom-bridges-textarea" 
                      placeholder="Paste your webtunnel bridges here...&#10;&#10;Example webtunnel bridges:&#10;webtunnel [2001:db8:adeb:7e0f:5140:7cd5:28b1:4503]:443 32F772D0970C2849B2B5BF9F0EC9D3F878DAEA43 url=https://files.bitrot.cz/Bho2k74VTFX6Bwr2XJG5V8gLhZEKgRQ5 ver=0.0.3&#10;webtunnel [2001:db8:57e6:c973:b296:4682:8c10:c049]:443 CA189269FB80216A1967ED19723B6D7639996663 url=https://goforwardbro.info/de1af89c3be2d3bbccc6cb34091f961f48caca14 ver=0.0.3"></textarea>
            
            <div class="bridge-examples">
                <strong>Supported Bridge Types:</strong>
                <code>webtunnel [IP]:port FINGERPRINT url=URL ver=VERSION</code>
                <code>obfs4 IP:port FINGERPRINT cert=CERT iat-mode=MODE</code>
                <code>meek IP:port url=URL front=DOMAIN</code>
                
                <div style="margin-top: 10px; color: #4dabf7;">
                    <i class="icon-info"></i> Webtunnel requires snowflake-proxy package
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
    
    let currentSettings = {
        bridge: 'webtunnel',
        use_custom: '1',
        custom_bridges: ''
    };
    
    let isApplying = false;

    function updateUIFromSettings() {
        bridgeModeText.innerText = currentSettings.bridge === 'none' ? 'Direct Connection' : 
                                  currentSettings.use_custom === '1' ? 'Custom Bridges' : 'Standard Bridges';
        
        // Обновляем кнопки типа моста
        bridgeTypeButtons.forEach(btn => {
            btn.classList.remove('selected');
            if (btn.dataset.bridgeType === currentSettings.bridge) {
                btn.classList.add('selected');
            }
        });
        
        // Обновляем текстовое поле
        customBridgesText.value = currentSettings.custom_bridges || '';
        
        // Если выбран "none", деактивируем текстовое поле
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
        const bridgeType = selectedBtn ? selectedBtn.dataset.bridgeType : 'webtunnel';
        const customBridges = customBridgesText.value.trim();
        
        // Валидация
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
            
            currentSettings.bridge = st.bridge || 'webtunnel';
            currentSettings.use_custom = st.use_custom || '1';
            currentSettings.custom_bridges = st.custom_bridges || '';
            
            updateUIFromSettings();
            updateConnectionUI(st.running, st.ip);
        });
    }

    // Event Listeners
    connectBtn.addEventListener('click', function() {
        if (!connectBtn.classList.contains('disabled')) {
            toggleService();
        }
    });

    disconnectBtn.addEventListener('click', function() {
        if (!disconnectBtn.classList.contains('disabled')) {
            toggleService();
        }
    });
    
    bridgeTypeButtons.forEach(btn => {
        btn.addEventListener('click', function() {
            bridgeTypeButtons.forEach(b => b.classList.remove('selected'));
            this.classList.add('selected');
            
            // Обновляем placeholder в зависимости от типа
            const type = this.dataset.bridgeType;
            if (type === 'webtunnel') {
                customBridgesText.placeholder = 'Paste webtunnel bridges...';
            } else if (type === 'obfs4') {
                customBridgesText.placeholder = 'Paste obfs4 bridges...';
            } else if (type === 'none') {
                customBridgesText.placeholder = 'Bridges disabled (direct connection)';
                customBridgesText.value = '';
            }
        });
    });
    
    saveBridgeBtn.addEventListener('click', saveBridgeSettings);

    // Initial load
    loadStatus();
    
    // Load debug log
    XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=get_debug_log', null, function(x, data) {
        if (data && data.log) {
            document.getElementById('log-output').textContent = data.log;
        }
    });

    // Background polling
    XHR.poll(5, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=status', null, function(x, st) {
        if (st) {
            currentSettings.bridge = st.bridge || 'webtunnel';
            currentSettings.use_custom = st.use_custom || '1';
            currentSettings.custom_bridges = st.custom_bridges || '';
            
            updateUIFromSettings();
            updateConnectionUI(st.running, st.ip);
        }
    });

    XHR.poll(2, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=get_debug_log', null, function(x, data) {
        if (data && data.log) {
            const logOutput = document.getElementById('log-output');
            logOutput.textContent = data.log;
            if(logOutput.scrollHeight - logOutput.clientHeight <= logOutput.scrollTop + 20) {
                logOutput.scrollTop = logOutput.scrollHeight;
            }
        }
    });
})();
</script>
<%+footer%>
EoL

    # Clean up old files
    rm -f /usr/lib/lua/luci/model/cbi/torplus_manager.lua 2>/dev/null
    rm -f /usr/lib/lua/luci/view/torplus_status_section.htm 2>/dev/null
    
    # Create debug log
    echo "TORPlus Webtunnel Edition installation started at $(date)" > "$DEBUG_LOG_FILE"

    # Write initial torrc with webtunnel focus
    cat > /etc/tor/torrc << 'EOF'
SocksPort 9050
UseBridges 1

# Webtunnel configuration (requires snowflake-proxy)
# ClientTransportPlugin webtunnel exec /usr/bin/snowflake-client

# Add your webtunnel bridges below (one per line):
# webtunnel [IP]:port FINGERPRINT url=URL ver=VERSION

# Example:
# webtunnel [2001:db8:adeb:7e0f:5140:7cd5:28b1:4503]:443 32F772D0970C2849B2B5BF9F0EC9D3F878DAEA43 url=https://files.bitrot.cz/Bho2k74VTFX6Bwr2XJG5V8gLhZEKgRQ5 ver=0.0.3
EOF
    
    # Enable and start Tor
    /etc/init.d/tor enable
    /etc/init.d/tor restart
    
    echo "TORPlus Webtunnel Edition installation completed."
}

# Run installation
install_torplus

# Clear cache and restart uhttpd
echo "Reloading LuCI UI..."
rm -rf /tmp/luci-* 2>/dev/null
rm -f /var/run/luci-indexcache 2>/dev/null

if [ -f /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/uhttpd reload 2>/dev/null
fi

cat << "EOM"

================================================
TORPlus Webtunnel Edition Installed!

Key Features:
✓ Webtunnel bridge support (primary)
✓ Snowflake client integration
✓ Custom bridge configuration
✓ No fake/placeholder bridges

Important:
1. For webtunnel support, install snowflake-proxy:
   opkg install snowflake-proxy
   
2. Get webtunnel bridges from:
   https://bridges.torproject.org/

3. Add bridges in the interface and click "Save & Apply"

Access: Services → TORPlus in LuCI
SOCKS5: 127.0.0.1:9050
================================================
EOM
