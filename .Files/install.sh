#!/bin/sh

# PeDitXOS Tools - TORPlus Installer v31.0 (Fixed for Services Menu)
# Fixed mkdir, menu location, and dependencies

echo ">>> Starting TORPlus installation..."
LOG_FILE="/tmp/peditxos_torplus_log.txt"
DEBUG_LOG_FILE="/tmp/torplus_debug.log"

# Function to show progress for long tasks
run_with_heartbeat() {
    COMMAND_TO_RUN="$1"
    ( eval "$COMMAND_TO_RUN" ) &
    CMD_PID=$!
    while kill -0 $CMD_PID >/dev/null 2>&1; do
        echo -n "."
        sleep 3
    done
    wait $CMD_PID
    return $?
}

# --- Main TORPlus installation function ---
install_torplus() {
    echo "Installing required packages..."
    run_with_heartbeat "opkg update"
    echo "Installing core packages..."
    opkg install obfs4proxy tor ca-certificates curl coreutils-base64
    echo "Installing LuCI dependencies..."
    opkg install luci-base luci-compat luci-lib-ipkg luci-lib-nixio
    
    echo "Creating TORPlus LuCI UI..."

    # Ensure the directory exists before writing the file
    mkdir -p /usr/lib/lua/luci/view/torplus
    
    # Check and create the UCI config file if it doesn't exist
    if [ ! -f /etc/config/torplus ]; then
        echo "Creating UCI configuration for torplus..."
        cat > /etc/config/torplus << 'EOF'
config settings 'settings'
    option bridge_type 'obfs4'
EOF
    fi
    
    # Ensure settings exist
    uci -q get torplus.settings >/dev/null 2>&1 || uci set torplus.settings=torplus
    uci -q set torplus.settings.bridge_type='obfs4'
    uci -q commit torplus

    # Write the LuCI controller file - РАЗМЕЩАЕМ В РАЗДЕЛЕ SERVICES!
    mkdir -p /usr/lib/lua/luci/controller
    cat > /usr/lib/lua/luci/controller/torplus.lua <<'EoL'
module("luci.controller.torplus", package.seeall)

function index()
    -- Проверяем наличие конфигурации
    local fs = require "nixio.fs"
    if not fs.access("/etc/config/torplus") then
        return
    end
    
    -- Размещаем в разделе Services (Сервисы)
    entry({"admin", "services", "torplus"}, template("torplus/main"), _("TORPlus"), 92)
    entry({"admin", "services", "torplus_api"}, call("api_handler")).leaf = true
end

function api_handler()
    local http = require("luci.http")
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local action = http.formvalue("action")
    local DEBUG_LOG_FILE = "/tmp/torplus_debug.log"

    if action == "status" then
        local running = sys.call("pgrep -f '/usr/sbin/tor' >/dev/null 2>&1") == 0
        local ip = "N/A"
        local bridge = uci:get("torplus", "settings", "bridge_type") or "obfs4"
        
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
        http.write_json({running = running, ip = ip, bridge = bridge})
        
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
        local bridge_type = http.formvalue("bridge_type") or "obfs4"
        
        sys.call("echo '--- Debug Log Started: $(date) ---' > " .. DEBUG_LOG_FILE)
        sys.call("echo 'Action: save_bridge, Bridge Type: " .. bridge_type .. "' >> " .. DEBUG_LOG_FILE)
        
        uci:set("torplus", "settings", "bridge_type", bridge_type)
        uci:commit("torplus")
        sys.call("echo 'UCI setting saved.' >> " .. DEBUG_LOG_FILE)

        local torrc_content = "SocksPort 9050\n"
        if bridge_type == "obfs4" then
            torrc_content = torrc_content .. "UseBridges 1\nClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy\nBridge obfs4 192.0.2.2:2 cert=ABC iat-mode=0"
        elseif bridge_type == "meek" then
            torrc_content = torrc_content .. "UseBridges 1\nClientTransportPlugin meek exec /usr/bin/meek-client\nBridge meek 192.0.2.3:3 url=https://ajax.aspnetcdn.com/ delay=1000"
        else
            torrc_content = torrc_content .. "UseBridges 0"
        end

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
    
    # Write the LuCI view file (integrated HTML and JavaScript)
    cat > /usr/lib/lua/luci/view/torplus/main.htm <<'EoL'
<%+header%>
<style>
.torplus-container{
    max-width: 600px;
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
}
.torplus-value{
    font-weight: 700;
    color: #fff;
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
.bridge-btn-group{
    display: flex;
    gap: 10px;
    margin-top: 10px;
    justify-content: center;
}
.bridge-btn {
    padding: 10px 15px;
    background-color: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.2);
    color: #fff;
    border-radius: 8px;
    cursor: pointer;
    font-weight: 600;
    transition: all 0.2s ease;
}
.bridge-btn:hover {
    background-color: rgba(255, 255, 255, 0.2);
}
.bridge-btn.selected-bridge {
    background-color: #007bff;
    border-color: #007bff;
    color: #fff;
    transform: scale(1.05);
}
.bridge-btn.disabled {
    cursor: not-allowed;
    background-color: rgba(255, 255, 255, 0.05);
    color: #999;
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
    <h2>TORPlus Manager</h2>

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
    
    <div class="torplus-btn-group">
        <button id="connectBtn" class="torplus-btn btn-connect">Connect</button>
        <button id="disconnectBtn" class="torplus-btn btn-disconnect" style="display:none;">Disconnect</button>
    </div>

    <div class="bridge-settings">
        <div class="torplus-row">
            <span class="torplus-label">Active Bridge Type:</span>
            <span id="activeBridgeText" class="torplus-value">...</span>
        </div>
        <label>Change Bridge Type:</label>
        <div class="bridge-btn-group">
            <button class="bridge-btn" data-bridge-type="obfs4">obfs4</button>
            <button class="bridge-btn" data-bridge-type="meek">Meek</button>
            <button class="bridge-btn" data-bridge-type="none">None</button>
        </div>
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
    const activeBridgeText = document.getElementById('activeBridgeText');
    const logOutput = document.getElementById('log-output');
    const bridgeButtons = document.querySelectorAll('.bridge-btn-group .bridge-btn');
    
    let isApplying = false;

    function resetBridgeButtons() {
        bridgeButtons.forEach(btn => {
            btn.classList.remove('selected-bridge', 'disabled');
            btn.innerText = btn.dataset.bridgeType.charAt(0).toUpperCase() + btn.dataset.bridgeType.slice(1);
        });
    }

    function setBridgeUIState(bridgeType) {
        activeBridgeText.innerText = bridgeType;
        resetBridgeButtons();
        bridgeButtons.forEach(btn => {
            if (btn.dataset.bridgeType === bridgeType) {
                btn.classList.add('selected-bridge');
            }
        });
    }

    function updateConnectionUI(running, ip) {
        statusText.innerText = running ? 'Connected' : 'Disconnected';
        statusIndicator.className = 'torplus-status-indicator ' + (running ? 'status-connected' : 'status-disconnected');
        ipText.innerText = running ? (ip?.trim() || 'N/A') : 'N/A';
        
        connectBtn.style.display = running ? 'none' : 'inline-block';
        disconnectBtn.style.display = running ? 'inline-block' : 'none';

        if (!isApplying) {
            connectBtn.classList.remove('disabled');
            connectBtn.innerText = 'Connect';
            disconnectBtn.classList.remove('disabled');
            disconnectBtn.innerText = 'Disconnect';
        }
    }

    function toggleService() {
        isApplying = true;
        if (connectBtn.style.display !== 'none') {
            connectBtn.classList.add('disabled');
            connectBtn.innerText = 'Connecting...';
        } else {
            disconnectBtn.classList.add('disabled');
            disconnectBtn.innerText = 'Disconnecting...';
        }
        
        XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=toggle', null, function(x, data) {
            isApplying = false;
        });
    }

    function applyBridge(bridgeType) {
        setBridgeUIState(bridgeType);
        bridgeButtons.forEach(btn => btn.classList.add('disabled'));

        XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=save_bridge&bridge_type=' + bridgeType, null, function(x, data) {
            if (data && data.success) {
                alert('Bridge settings applied. Tor service is restarting...');
            } else {
                alert('Failed to apply bridge settings.');
            }
            bridgeButtons.forEach(btn => btn.classList.remove('disabled'));
        });
    }

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
    
    bridgeButtons.forEach(btn => {
        btn.addEventListener('click', function() {
            const bridgeType = this.dataset.bridgeType;
            if (this.classList.contains('selected-bridge') || this.classList.contains('disabled')) {
                return;
            }
            applyBridge(bridgeType);
        });
    });

    // Initial load
    XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=status', null, function(x, st) {
        if (!st) return;
        setBridgeUIState(st.bridge || 'obfs4');
        updateConnectionUI(st.running, st.ip);
    });
    
    // Initial log load
    XHR.get('<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=get_debug_log', null, function(x, data) {
        if (data && data.log) {
            logOutput.textContent = data.log;
        }
    });

    // Background polling
    XHR.poll(5, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=status', null, function(x, st) {
        if (st) {
            updateConnectionUI(st.running, st.ip);
        }
    });

    XHR.poll(2, '<%=luci.dispatcher.build_url("admin/services/torplus_api")%>?action=get_debug_log', null, function(x, data) {
        if (data && data.log) {
            logOutput.textContent = data.log;
            const isScrolledToBottom = logOutput.scrollHeight - logOutput.clientHeight <= logOutput.scrollTop + 20;
            if(isScrolledToBottom) {
                logOutput.scrollTop = logOutput.scrollHeight;
            }
        }
    });
})();
</script>
<%+footer%>
EoL

    # Remove old LuCI files to prevent conflicts
    rm -f /usr/lib/lua/luci/model/cbi/torplus_manager.lua 2>/dev/null
    rm -f /usr/lib/lua/luci/view/torplus_status_section.htm 2>/dev/null
    
    # Create and clear the debug log file
    echo "TORPlus installation started at $(date)" > "$DEBUG_LOG_FILE"

    # Write the initial torrc file with obfs4 bridge as default
    cat > /etc/tor/torrc << 'EOF'
SocksPort 9050
UseBridges 1
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
Bridge obfs4 192.0.2.2:2 cert=ABC iat-mode=0
EOF
    
    # Enable and start the Tor service
    /etc/init.d/tor enable
    /etc/init.d/tor restart
    
    # Configure Passwall or Passwall2 with detailed settings
    if uci show passwall2 >/dev/null 2>&1; then
        echo "Configuring Passwall2..."
        uci set passwall2.TorNode=nodes
        uci set passwall2.TorNode.remarks='Tor'
        uci set passwall2.TorNode.type='Xray'
        uci set passwall2.TorNode.protocol='socks'
        uci set passwall2.TorNode.server='127.0.0.1'
        uci set passwall2.TorNode.port='9050'
        uci set passwall2.TorNode.address='127.0.0.1'
        uci set passwall2.TorNode.tls='0'
        uci set passwall2.TorNode.transport='tcp'
        uci set passwall2.TorNode.tcp_guise='none'
        uci set passwall2.TorNode.tcpMptcp='0'
        uci set passwall2.TorNode.tcpNoDelay='0'
        uci commit passwall2
        echo "Passwall2 configured with TOR node."
    elif uci show passwall >/dev/null 2>&1; then
        echo "Configuring Passwall..."
        uci set passwall.TorNode=nodes
        uci set passwall.TorNode.remarks='Tor'
        uci set passwall.TorNode.type='Xray'
        uci set passwall.TorNode.protocol='socks'
        uci set passwall.TorNode.server='127.0.0.1'
        uci set passwall.TorNode.port='9050'
        uci set passwall.TorNode.address='127.0.0.1'
        uci set passwall.TorNode.tls='0'
        uci set passwall.TorNode.transport='tcp'
        uci set passwall.TorNode.tcp_guise='none'
        uci set passwall.TorNode.tcpMptcp='0'
        uci set passwall.TorNode.tcpNoDelay='0'
        uci commit passwall
        echo "Passwall configured with TOR node."
    fi
    
    echo "TORPlus installation completed successfully."
}

# Run the installation function
install_torplus

# Clear LuCI cache and restart uhttpd to display the new page
echo "Reloading LuCI UI..."
rm -rf /tmp/luci-* 2>/dev/null
rm -f /var/run/luci-indexcache 2>/dev/null
rm -f /www/luci-static/resources/cbi.js 2>/dev/null

# Restart uhttpd
if [ -f /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/uhttpd reload 2>/dev/null
fi

echo "Operation completed successfully."

# Use cat heredoc for robust multi-line output
cat << "EOM"

================================================
 ______      _____   _      _    _     _____       
 (_____ \    (____ \ (_)_   \ \  / /   / ___ \      
 _____) )___ _   \ \ _| |_  \ \/ /   | |   | | ___ 
 |  ____/ _  ) |   | | |  _)  )  (    | |   | |/___)
 | |   ( (/ /| |__/ /| | |__ / /\ \   | |___| |___ |
 |_|    \____)_____/ |_|\___)_/  \_\   \_____/(___/ 
                                                    
                                       TORPlus by PeDitX

Installation Complete!
TORPlus is now available in LuCI web interface:

1. Open: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')
2. Go to: Services → TORPlus

Direct link: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')/cgi-bin/luci/admin/services/torplus

SOCKS5 Proxy: 127.0.0.1:9050
================================================
EOM
