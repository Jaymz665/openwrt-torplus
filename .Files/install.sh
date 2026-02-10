#!/bin/sh

# PeDitXOS Tools - TORPlus Installer v30.3 (Simplified Working Version)

echo ">>> Starting TORPlus installation..."
LOG_FILE="/tmp/peditxos_torplus_log.txt"
DEBUG_LOG_FILE="/tmp/torplus_debug.log"

# --- Main TORPlus installation function ---
install_torplus() {
    echo "Installing required packages..."
    opkg update
    opkg install obfs4proxy tor ca-certificates curl coreutils-base64 luci-lib-ipkg
    
    echo "Creating TORPlus LuCI UI..."

    # Ensure the directory exists before writing the file
    mkdir -p /usr/lib/lua/luci/view/torplus
    
    # Create UCI config file
    cat > /etc/config/torplus << 'EOF'
config settings 'settings'
    option bridge_type 'obfs4'
EOF

    # Write the LuCI controller file - размещаем в разделе Services
    mkdir -p /usr/lib/lua/luci/controller
    cat > /usr/lib/lua/luci/controller/torplus.lua <<'EoL'
module("luci.controller.torplus", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/torplus") then
        return
    end
    
    entry({"admin", "services", "torplus"}, template("torplus/main"), _("TORPlus"), 92)
    entry({"admin", "services", "torplus", "api"}, call("api_handler")).leaf = true
end

function api_handler()
    local http = require("luci.http")
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    local DEBUG_LOG_FILE = "/tmp/torplus_debug.log"
    local action = http.formvalue("action")

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
    
    # Write the LuCI view file
    cat > /usr/lib/lua/luci/view/torplus/main.htm <<'EoL'
<%+header%>
<style>
.torplus-container {
    max-width: 800px;
    margin: 20px auto;
    padding: 20px;
    background: #f5f5f5;
    border-radius: 8px;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}
.torplus-header {
    text-align: center;
    margin-bottom: 30px;
    border-bottom: 2px solid #ddd;
    padding-bottom: 15px;
}
.status-box {
    background: white;
    padding: 15px;
    border-radius: 6px;
    margin-bottom: 20px;
    border-left: 4px solid #007bff;
}
.status-indicator {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 8px;
}
.status-connected { background-color: #28a745; }
.status-disconnected { background-color: #dc3545; }
.btn-group {
    display: flex;
    gap: 10px;
    margin: 20px 0;
}
.btn {
    padding: 10px 20px;
    border: none;
    border-radius: 4px;
    cursor: pointer;
    font-weight: bold;
}
.btn-connect { background: #28a745; color: white; }
.btn-disconnect { background: #dc3545; color: white; }
.btn-bridge { background: #007bff; color: white; }
.bridge-options {
    display: flex;
    gap: 10px;
    margin-top: 10px;
}
.debug-log {
    background: #2d2d2d;
    color: #00ff00;
    padding: 10px;
    border-radius: 4px;
    font-family: monospace;
    font-size: 12px;
    max-height: 200px;
    overflow-y: auto;
    margin-top: 20px;
}
</style>

<div class="torplus-container">
    <div class="torplus-header">
        <h2>TORPlus Manager</h2>
    </div>
    
    <div class="status-box">
        <h3>Status</h3>
        <p>Service: <span id="statusText">Checking...</span> <span id="statusIndicator" class="status-indicator status-disconnected"></span></p>
        <p>IP Address: <span id="ipText">...</span></p>
        <p>Bridge Type: <span id="bridgeText">...</span></p>
    </div>
    
    <div class="btn-group">
        <button id="connectBtn" class="btn btn-connect">Connect</button>
        <button id="disconnectBtn" class="btn btn-disconnect" style="display:none;">Disconnect</button>
    </div>
    
    <div class="status-box">
        <h3>Bridge Settings</h3>
        <div class="bridge-options">
            <button class="btn btn-bridge" data-bridge="obfs4">obfs4</button>
            <button class="btn btn-bridge" data-bridge="meek">Meek</button>
            <button class="btn btn-bridge" data-bridge="none">None</button>
        </div>
    </div>
    
    <div class="status-box">
        <h3>Debug Log</h3>
        <div id="debugLog" class="debug-log">Waiting...</div>
    </div>
</div>

<script>
document.addEventListener('DOMContentLoaded', function() {
    const statusText = document.getElementById('statusText');
    const statusIndicator = document.getElementById('statusIndicator');
    const ipText = document.getElementById('ipText');
    const bridgeText = document.getElementById('bridgeText');
    const connectBtn = document.getElementById('connectBtn');
    const disconnectBtn = document.getElementById('disconnectBtn');
    const debugLog = document.getElementById('debugLog');
    const bridgeButtons = document.querySelectorAll('.btn-bridge');
    
    function updateStatus() {
        fetch('<%=luci.dispatcher.build_url("admin/services/torplus/api")%>?action=status')
            .then(response => response.json())
            .then(data => {
                if (data.running) {
                    statusText.textContent = 'Connected';
                    statusIndicator.className = 'status-indicator status-connected';
                    connectBtn.style.display = 'none';
                    disconnectBtn.style.display = 'inline-block';
                } else {
                    statusText.textContent = 'Disconnected';
                    statusIndicator.className = 'status-indicator status-disconnected';
                    connectBtn.style.display = 'inline-block';
                    disconnectBtn.style.display = 'none';
                }
                ipText.textContent = data.ip || 'N/A';
                bridgeText.textContent = data.bridge || 'obfs4';
                
                bridgeButtons.forEach(btn => {
                    if (btn.dataset.bridge === data.bridge) {
                        btn.style.opacity = '1';
                        btn.style.fontWeight = 'bold';
                    } else {
                        btn.style.opacity = '0.7';
                        btn.style.fontWeight = 'normal';
                    }
                });
            })
            .catch(error => {
                console.error('Error:', error);
            });
    }
    
    function updateLog() {
        fetch('<%=luci.dispatcher.build_url("admin/services/torplus/api")%>?action=get_debug_log')
            .then(response => response.json())
            .then(data => {
                if (data.log) {
                    debugLog.textContent = data.log;
                    debugLog.scrollTop = debugLog.scrollHeight;
                }
            });
    }
    
    connectBtn.addEventListener('click', function() {
        fetch('<%=luci.dispatcher.build_url("admin/services/torplus/api")%>?action=toggle')
            .then(() => setTimeout(updateStatus, 2000));
    });
    
    disconnectBtn.addEventListener('click', function() {
        fetch('<%=luci.dispatcher.build_url("admin/services/torplus/api")%>?action=toggle')
            .then(() => setTimeout(updateStatus, 2000));
    });
    
    bridgeButtons.forEach(btn => {
        btn.addEventListener('click', function() {
            const bridge = this.dataset.bridge;
            fetch('<%=luci.dispatcher.build_url("admin/services/torplus/api")%>?action=save_bridge&bridge_type=' + bridge)
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        alert('Bridge settings updated. Restarting Tor...');
                        setTimeout(updateStatus, 3000);
                    }
                });
        });
    });
    
    updateStatus();
    updateLog();
    
    setInterval(updateStatus, 10000);
    setInterval(updateLog, 5000);
});
</script>
<%+footer%>
EoL

    # Write the initial torrc file
    cat > /etc/tor/torrc << 'EOF'
SocksPort 9050
UseBridges 1
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
Bridge obfs4 192.0.2.2:2 cert=ABC iat-mode=0
EOF
    
    # Create debug log file
    echo "TORPlus installation started" > "$DEBUG_LOG_FILE"
    
    # Enable and start the Tor service
    /etc/init.d/tor enable
    /etc/init.d/tor restart
    
    echo "TORPlus installation completed successfully."
}

# Run installation
install_torplus

# Clear cache and restart uhttpd
echo "Reloading LuCI UI..."
rm -rf /tmp/luci-*
rm -f /var/run/luci-indexcache
/etc/init.d/uhttpd restart 2>/dev/null || service uhttpd restart

# Create success marker
cat << "EOM"

 ______      _____   _      _    _     _____       
 (_____ \    (____ \ (_)_   \ \  / /   / ___ \      
 _____) )___ _   \ \ _| |_  \ \/ /   | |   | | ___ 
 |  ____/ _  ) |   | | |  _)  )  (    | |   | |/___)
 | |   ( (/ /| |__/ /| | |__ / /\ \   | |___| |___ |
 |_|    \____)_____/ |_|\___)_/  \_\   \_____/(___/ 
                                                    
                                       TORPlus by PeDitX

Installation complete!
Access TORPlus at: Services → TORPlus in LuCI web interface.

EOM
