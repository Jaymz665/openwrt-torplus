#!/bin/sh

# TORPlus Installer - Minimal Working Version
# Для систем без полного LuCI

echo ">>> Installing TORPlus..."
LOG_FILE="/tmp/torplus_install.log"

# Логирование
exec > "$LOG_FILE" 2>&1

# Установка пакетов
echo "Updating package lists..."
opkg update

echo "Installing required packages..."
opkg install tor obfs4proxy curl ca-certificates

# Создание директорий
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/view/torplus

# Создание UCI конфигурации
cat > /etc/config/torplus << 'EOF'
config settings 'settings'
    option bridge_type 'obfs4'
EOF

# Простой контроллер LuCI
cat > /usr/lib/lua/luci/controller/torplus.lua << 'EOF'
module("luci.controller.torplus", package.seeall)

function index()
    entry({"admin", "services", "torplus"}, call("action_torplus"), _("TORPlus"), 99)
end

function action_torplus()
    local template = require("luci.template")
    local http = require("luci.http")
    
    if http.formvalue("action") == "toggle" then
        os.execute("/etc/init.d/tor toggle >/dev/null 2>&1")
        http.redirect(luci.dispatcher.build_url("admin/services/torplus"))
        return
    elseif http.formvalue("action") == "change_bridge" then
        local bridge = http.formvalue("bridge") or "obfs4"
        os.execute("uci set torplus.settings.bridge_type='" .. bridge .. "' && uci commit torplus")
        
        local torrc = "SocksPort 9050\n"
        if bridge == "obfs4" then
            torrc = torrc .. "UseBridges 1\nClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy\nBridge obfs4 192.0.2.2:2 cert=ABC iat-mode=0"
        elseif bridge == "meek" then
            torrc = torrc .. "UseBridges 1\nClientTransportPlugin meek exec /usr/bin/meek-client\nBridge meek 192.0.2.3:3 url=https://ajax.aspnetcdn.com/ delay=1000"
        else
            torrc = torrc .. "UseBridges 0"
        end
        
        local f = io.open("/etc/tor/torrc", "w")
        if f then
            f:write(torrc)
            f:close()
        end
        
        os.execute("/etc/init.d/tor restart >/dev/null 2>&1")
        http.redirect(luci.dispatcher.build_url("admin/services/torplus"))
        return
    end
    
    -- Получение статуса
    local running = os.execute("pidof tor >/dev/null") == 0
    local ip = "N/A"
    local bridge = "obfs4"
    
    if running then
        ip = luci.sys.exec("curl --socks5 127.0.0.1:9050 -s -m 3 http://ifconfig.me 2>/dev/null || echo 'N/A'")
        ip = ip:gsub("\n", "")
    end
    
    local uci = luci.model.uci.cursor()
    bridge = uci:get("torplus", "settings", "bridge_type") or "obfs4"
    
    template.render("torplus/simple", {
        running = running,
        ip = ip,
        bridge = bridge
    })
end
EOF

# Простой HTML шаблон
mkdir -p /usr/lib/lua/luci/view/torplus
cat > /usr/lib/lua/luci/view/torplus/simple.htm << 'EOF'
<%+header%>
<div style="max-width: 800px; margin: 20px auto; padding: 20px; background: #f5f5f5; border-radius: 8px;">
    <h2>TORPlus Manager</h2>
    
    <div style="background: white; padding: 15px; border-radius: 6px; margin: 15px 0; border-left: 4px solid #007bff;">
        <h3>Status</h3>
        <p>Service: 
            <% if running then %>
                <span style="color: green; font-weight: bold;">● Running</span>
            <% else %>
                <span style="color: red; font-weight: bold;">● Stopped</span>
            <% end %>
        </p>
        <p>IP Address: <%=ip%></p>
        <p>Bridge Type: <%=bridge%></p>
    </div>
    
    <div style="margin: 20px 0;">
        <form method="post" style="display: inline;">
            <input type="hidden" name="action" value="toggle">
            <% if running then %>
                <button type="submit" style="padding: 10px 20px; background: #dc3545; color: white; border: none; border-radius: 4px; cursor: pointer;">
                    Stop TOR
                </button>
            <% else %>
                <button type="submit" style="padding: 10px 20px; background: #28a745; color: white; border: none; border-radius: 4px; cursor: pointer;">
                    Start TOR
                </button>
            <% end %>
        </form>
    </div>
    
    <div style="background: white; padding: 15px; border-radius: 6px; margin: 15px 0;">
        <h3>Bridge Settings</h3>
        <form method="post">
            <input type="hidden" name="action" value="change_bridge">
            <div style="margin: 10px 0;">
                <button type="submit" name="bridge" value="obfs4" 
                    style="padding: 8px 16px; margin: 0 5px; background: <% if bridge == "obfs4" then %>#007bff<% else %>#6c757d<% end %>; color: white; border: none; border-radius: 4px; cursor: pointer;">
                    obfs4
                </button>
                <button type="submit" name="bridge" value="meek"
                    style="padding: 8px 16px; margin: 0 5px; background: <% if bridge == "meek" then %>#007bff<% else %>#6c757d<% end %>; color: white; border: none; border-radius: 4px; cursor: pointer;">
                    Meek
                </button>
                <button type="submit" name="bridge" value="none"
                    style="padding: 8px 16px; margin: 0 5px; background: <% if bridge == "none" then %>#007bff<% else %>#6c757d<% end %>; color: white; border: none; border-radius: 4px; cursor: pointer;">
                    None
                </button>
            </div>
        </form>
    </div>
    
    <div style="background: white; padding: 15px; border-radius: 6px; margin: 15px 0;">
        <h3>Connection Information</h3>
        <p>SOCKS5 Proxy: 127.0.0.1:9050</p>
        <p>Use this proxy in your applications to route traffic through TOR.</p>
    </div>
</div>
<%+footer%>
EOF

# Конфигурация Tor
cat > /etc/tor/torrc << 'EOF'
SocksPort 9050
UseBridges 1
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
Bridge obfs4 192.0.2.2:2 cert=ABC iat-mode=0
EOF

# Включение и запуск Tor
/etc/init.d/tor enable
/etc/init.d/tor restart

# Очистка кэша LuCI
echo "Clearing LuCI cache..."
rm -rf /tmp/luci-* 2>/dev/null
rm -f /var/run/luci-indexcache 2>/dev/null

# Проверка наличия uhttpd
if [ -f /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/uhttpd reload 2>/dev/null
fi

echo "================================================"
echo "TORPlus Installation Complete!"
echo ""
echo "To access TORPlus:"
echo "1. Open LuCI web interface: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"
echo "2. Go to: Services → TORPlus"
echo ""
echo "Direct link: http://$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')/cgi-bin/luci/admin/services/torplus"
echo ""
echo "SOCKS5 Proxy: 127.0.0.1:9050"
echo "================================================"
