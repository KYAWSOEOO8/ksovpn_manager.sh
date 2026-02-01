#!/bin/bash

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USER_DB="$CONFIG_DIR/udpusers.db"
SYSTEMD_SERVICE="/etc/systemd/system/hysteria-server.service"

# Web server variables (for menu 14)
WEB_DIR="/var/www/html/udpserver"
WEB_STATUS_FILE="$WEB_DIR/online"
WEB_APP_FILE="$WEB_DIR/online_app"
WEB_SYSTEM_FILE="$WEB_DIR/system_info"
DEFAULT_LIMIT="2500"

mkdir -p "$CONFIG_DIR"
touch "$USER_DB"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# =================================================================
# === Functions for Menu 1 and all related functions ===
# =================================================================

# Function to initialize database (add expire_date column)
init_database() {
    sqlite3 "$USER_DB" "CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT, 
        username TEXT UNIQUE NOT NULL, 
        password TEXT NOT NULL,
        expire_date INTEGER DEFAULT 0 NOT NULL
    );"
    
    # Add expire_date column if it doesn't exist
    sqlite3 "$USER_DB" "ALTER TABLE users ADD COLUMN expire_date INTEGER DEFAULT 0 NOT NULL" 2>/dev/null || true
    sqlite3 "$USER_DB" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1
}

# Fetch only users that haven't expired
fetch_users() {
    local now_ts=$(date +%s)
    if [[ -f "$USER_DB" ]]; then
        sqlite3 "$USER_DB" "SELECT username || ':' || password FROM users WHERE expire_date = 0 OR expire_date > $now_ts;" | paste -sd, -
    fi
}

# Update config.json file with active users
update_userpass_config() {
    echo -e "${BLUE}Updating Hysteria configuration with active users...${NC}"
    local users=$(fetch_users)
    local user_array
    
    if [[ -z "$users" ]]; then
        user_array="[]"
    else
        user_array="[$(echo "$users" | awk -F, '{for(i=1;i<=NF;i++) printf "\"" $i "\"" ((i==NF) ? "" : ",")}')]"
    fi
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Configuration file $CONFIG_FILE not found!${NC}"
        return 1
    fi
    
    jq ".auth.config = $user_array" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Configuration updated successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to update configuration${NC}"
        return 1
    fi
}

# Menu 1: Add new user (with expiration date)
add_user() {
    echo -e "\n${BLUE}Add new user${NC}"
    echo -e "${BLUE}Enter username:${NC}"
    read -r username
    if [[ -z "$username" ]]; then
        echo -e "${RED}Username cannot be empty${NC}"
        return
    fi
    
    echo -e "${BLUE}Enter password:${NC}"
    read -r password
    if [[ -z "$password" ]]; then
        echo -e "${RED}Password cannot be empty${NC}"
        return
    fi
    
    echo -e "${BLUE}Enter number of days to use (e.g., 30). Enter 0 for unlimited:${NC}"
    read -r duration_days
    
    if ! [[ "$duration_days" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid number of days${NC}"
        return
    fi
    
    local expire_timestamp=0
    if [[ "$duration_days" -gt 0 ]]; then
        expire_timestamp=$(date -d "+$duration_days days" +%s)
        echo -e "${CYAN}User will expire on: $(date -d "@$expire_timestamp" '+%Y-%m-%d %H:%M:%S')${NC}"
    else
        echo -e "${CYAN}User has unlimited access${NC}"
    fi
    
    sqlite3 "$USER_DB" "INSERT INTO users (username, password, expire_date) VALUES ('$username', '$password', $expire_timestamp);" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ User '$username' added successfully${NC}"
        if update_userpass_config; then
            systemctl restart hysteria-server
        fi
    else
        echo -e "${RED}✗ Failed to add user (maybe user '$username' already exists?)${NC}"
    fi
}

# Menu 2: Edit user (password / expiration date)
edit_user() {
    echo -e "\n${BLUE}Enter the username to edit:${NC}"
    read -r username
    
    local user_exists=$(sqlite3 "$USER_DB" "SELECT id FROM users WHERE username='$username';" 2>/dev/null)
    if [[ -z "$user_exists" ]]; then
        echo -e "${RED}User '$username' not found${NC}"
        return
    fi
    
    echo -e "${CYAN}Editing user: $username${NC}"
    echo "1. Change password"
    echo "2. Set new expiration date"
    echo "Select option:"
    read -r choice
    
    local restart_needed=0
    
    case $choice in
        1)
            echo -e "${BLUE}Enter new password:${NC}"
            read -r password
            if [[ -z "$password" ]]; then
                echo -e "${RED}Password cannot be empty${NC}"
                return
            fi
            sqlite3 "$USER_DB" "UPDATE users SET password = '$password' WHERE username = '$username';" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}✓ Password updated for '$username' successfully${NC}"
                restart_needed=1
            else
                echo -e "${RED}✗ Failed to update password${NC}"
            fi
            ;;
        2)
            echo -e "${BLUE}Enter new number of days (from today). Enter 0 for unlimited:${NC}"
            read -r duration_days
            
            if ! [[ "$duration_days" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Invalid number of days${NC}"
                return
            fi
            
            local expire_timestamp=0
            if [[ "$duration_days" -gt 0 ]]; then
                expire_timestamp=$(date -d "+$duration_days days" +%s)
                echo -e "${CYAN}User will expire on: $(date -d "@$expire_timestamp" '+%Y-%m-%d %H:%M:%S')${NC}"
            else
                echo -e "${CYAN}User has unlimited access${NC}"
            fi
            
            sqlite3 "$USER_DB" "UPDATE users SET expire_date = $expire_timestamp WHERE username = '$username';" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}✓ Expiration date updated for '$username' successfully${NC}"
                restart_needed=1
            else
                echo -e "${RED}✗ Failed to update expiration date${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            ;;
    esac
    
    if [[ "$restart_needed" -eq 1 ]]; then
        if update_userpass_config; then
            systemctl restart hysteria-server
        fi
    fi
}

# Menu 3: Delete user
delete_user() {
    echo -e "\n${BLUE}Enter the username to delete:${NC}"
    read -r username
    
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username = '$username';" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ User '$username' deleted successfully${NC}"
        if update_userpass_config; then
            systemctl restart hysteria-server
        fi
    else
        echo -e "${RED}✗ Failed to delete user${NC}"
    fi
}

# Menu 4: Show all users (with passwords and expiration dates)
show_users() {
    echo -e "\n${BLUE}===== Current Users =====${NC}"
    local user_count=$(sqlite3 "$USER_DB" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
    echo -e "${CYAN}Total users: $user_count${NC}\n"
    
    if [[ $user_count -gt 0 ]]; then
        echo -e "${GREEN}Username\t\tPassword\t\tExpiration Date\t\tStatus${NC}"
        echo "────────────────────────────────────────────────────────────────────────────────"
        local now_ts=$(date +%s)
        
        sqlite3 "$USER_DB" "SELECT username, password, expire_date FROM users;" 2>/dev/null | while IFS='|' read -r username password expire_date; do
            local status
            local expiry_str
            
            if [[ "$expire_date" -eq 0 ]]; then
                expiry_str="Unlimited"
                status="${GREEN}Active${NC}"
            elif [[ "$expire_date" -gt "$now_ts" ]]; then
                expiry_str=$(date -d "@$expire_date" '+%Y-%m-%d %H:%M:%S')
                status="${GREEN}Active${NC}"
            else
                expiry_str=$(date -d "@$expire_date" '+%Y-%m-%d %H:%M:%S')
                status="${RED}Expired${NC}"
            fi
            
            echo -e "$(printf "%-20s\t%-20s\t%-20s\t" "$username" "$password" "$expiry_str")$status"
        done
    else
        echo -e "${YELLOW}No users found${NC}"
    fi
}

# =================================================================
# === Functions for Menu 14 and all related functions ===
# =================================================================

# Function to check if web server is enabled
is_web_enabled() {
    if [[ -f "/etc/nginx/sites-enabled/udp-status" ]] && systemctl is-active nginx >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to get IPv4 address
get_ipv4() {
    local ip=$(curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null)
    if [[ -z "$ip" ]] || [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi
    echo "$ip"
}

# Function to update system information for web dashboard
update_system_info() {
    local server_ip=$(get_ipv4)
    local domain=$(get_domain)
    local obfs=$(get_obfuscation)
    local online_count=$(cat "$WEB_STATUS_FILE" 2>/dev/null || echo "0")
    local cpu_cores=$(nproc)
    
    # Use vmstat instead of top for lighter processing
    local cpu_usage=$(vmstat 1 2 | tail -1 | awk '{print 100 - $15}')
    
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local mem_used=$(free -m | awk 'NR==2{print $3}')
    local mem_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")
    
    local hysteria_status="offline"
    if systemctl is-active hysteria-server >/dev/null 2>&1; then
        hysteria_status="online"
    fi
    
    local web_status="off"
    if is_web_enabled; then
        web_status="on"
    fi
    
    cat > "$WEB_SYSTEM_FILE" << EOF
{
    "server_ip": "$server_ip",
    "domain": "$domain",
    "obfuscation": "$obfs",
    "online": "$online_count",
    "cpu_cores": "$cpu_cores",
    "cpu_usage": "$cpu_usage",
    "mem_total": "$mem_total",
    "mem_used": "$mem_used",
    "mem_percent": "$mem_percent",
    "hysteria_status": "$hysteria_status",
    "web_status": "$web_status"
}
EOF
    chmod 666 "$WEB_SYSTEM_FILE" 2>/dev/null
}

# Function to get domain from config
get_domain() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local domain=$(jq -r '.listen // empty' "$CONFIG_FILE" 2>/dev/null | cut -d':' -f1)
        if [[ -z "$domain" ]]; then
            domain=$(get_ipv4)
        fi
        echo "$domain"
    else
        echo $(get_ipv4)
    fi
}

# Function to get obfuscation from config
get_obfuscation() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local obfs=$(jq -r '.obfs // empty' "$CONFIG_FILE" 2>/dev/null)
        if [[ -z "$obfs" ]] || [[ "$obfs" == "null" ]]; then
            echo "None"
        else
            echo "$obfs"
        fi
    else
        echo "None"
    fi
}

# Menu 14: Toggle web server and dashboard
toggle_web_server() {
    if is_web_enabled; then
        echo -e "\n${YELLOW}Web server is currently: ${GREEN}ON${NC}"
        echo -e "${BLUE}Do you want to turn it off? (yes/no):${NC}"
        read -r confirm
        
        if [[ "$confirm" == "yes" ]]; then
            rm -f /etc/nginx/sites-enabled/udp-status
            
            # Restore default config when turning off web server
            if [[ -f "/etc/nginx/sites-available/default" ]]; then
                 ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
            fi
            
            systemctl reload nginx 2>/dev/null
            echo -e "${GREEN}✓ Web server turned off${NC}"
        else
            echo -e "${YELLOW}Cancelled${NC}"
        fi
    else
        echo -e "\n${YELLOW}Web server is currently: ${RED}OFF${NC}"
        echo -e "${BLUE}Do you want to turn it on? (yes/no):${NC}"
        read -r confirm
        
        if [[ "$confirm" == "yes" ]]; then
            if ! command -v nginx &> /dev/null; then
                echo -e "${YELLOW}Installing nginx...${NC}"
                apt-get update -y && apt-get install -y nginx
                systemctl start nginx
                systemctl enable nginx
            fi
            
            mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
            
            if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
                sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
            fi
            
            # Nginx config with headers for inline viewing (no download)
            cat > /etc/nginx/sites-available/udp-status << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    
    location /udpserver/ {
        autoindex on;
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }
    
    location = /udpserver/online {
        default_type "text/plain; charset=utf-8";
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header X-Content-Type-Options "nosniff";
        add_header Content-Disposition "inline"; # Show as API (prevent download)
    }
    
    location = /udpserver/online_app {
        default_type "application/json; charset=utf-8";
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header X-Content-Type-Options "nosniff";
        add_header Content-Disposition "inline"; # Show as API (prevent download)
    }
    
    location = /udpserver/system_info {
        default_type "application/json; charset=utf-8";
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header X-Content-Type-Options "nosniff";
        add_header Content-Disposition "inline"; # Show as API (prevent download)
    }
}
NGINXEOF

            ln -sf /etc/nginx/sites-available/udp-status /etc/nginx/sites-enabled/udp-status
            
            # Fix Conflict: Remove default file that might cause conflict
            rm -f /etc/nginx/sites-enabled/default
            
            # Create web dashboard (only copy link buttons)
            mkdir -p "$WEB_DIR"
            
            cat > "$WEB_DIR/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hysteria UDP Manager</title>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500;700&display=swap" rel="stylesheet">
    <link href="https://fonts.googleapis.com/icon?family=Material+Icons" rel="stylesheet">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Roboto', -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        
        .app-bar {
            background: rgba(255, 255, 255, 0.98);
            color: #333;
            padding: 32px;
            border-radius: 16px;
            box-shadow: 0 8px 32px rgba(0,0,0,0.15);
            margin-bottom: 24px;
            text-align: center;
        }
        
        .app-bar h1 {
            font-size: 36px;
            font-weight: 700;
            margin-bottom: 12px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .app-bar .subtitle {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            color: #666;
            font-size: 15px;
        }
        
        .pulse-dot {
            width: 10px;
            height: 10px;
            background: #4caf50;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }
        
        @keyframes pulse {
            0%, 100% { opacity: 1; transform: scale(1); }
            50% { opacity: 0.6; transform: scale(1.2); }
        }
        
        .card {
            background: rgba(255, 255, 255, 0.98);
            border-radius: 16px;
            box-shadow: 0 8px 32px rgba(0,0,0,0.15);
            padding: 32px;
            margin-bottom: 24px;
            transition: all 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-4px);
            box-shadow: 0 12px 48px rgba(0,0,0,0.2);
        }
        
        .card-title {
            font-size: 15px;
            font-weight: 600;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 1.5px;
            margin-bottom: 24px;
            display: flex;
            align-items: center;
            gap: 10px;
            padding-bottom: 16px;
            border-bottom: 2px solid #f0f0f0;
        }
        
        .card-title .material-icons {
            font-size: 24px;
            color: #667eea;
        }
        
        .online-hero {
            text-align: center;
            padding: 48px 20px;
            background: linear-gradient(135deg, #667eea15 0%, #764ba215 100%);
            border-radius: 12px;
        }
        
        .online-count {
            font-size: 120px;
            font-weight: 300;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            line-height: 1;
            margin: 24px 0;
        }
        
        .online-label {
            font-size: 20px;
            color: #666;
            font-weight: 500;
            text-transform: uppercase;
            letter-spacing: 2px;
        }
        
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }
        
        .info-item {
            background: linear-gradient(135deg, #667eea15 0%, #764ba215 100%);
            padding: 20px;
            border-radius: 12px;
            text-align: center;
        }
        
        .info-label {
            font-size: 12px;
            color: #999;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 8px;
        }
        
        .info-value {
            font-size: 18px;
            color: #333;
            font-weight: 600;
            word-break: break-all;
        }
        
        .api-links {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
        }
        
        .api-link-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            border-radius: 12px;
            padding: 28px;
            color: white;
            transition: all 0.3s ease;
        }
        
        .api-link-card:hover {
            transform: translateY(-4px);
            box-shadow: 0 12px 32px rgba(102, 126, 234, 0.4);
        }
        
        .api-link-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 16px;
        }
        
        .api-link-header .material-icons {
            font-size: 32px;
        }
        
        .api-link-title {
            font-size: 20px;
            font-weight: 600;
            letter-spacing: 1px;
        }
        
        .api-url-box {
            background: rgba(255, 255, 255, 0.2);
            padding: 14px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            font-size: 13px;
            word-break: break-all;
            margin-bottom: 16px;
            border: 1px solid rgba(255, 255, 0, 0.3);
        }
        
        .api-buttons {
            display: flex;
            gap: 12px;
        }
        
        .btn {
            flex: 1;
            background: rgba(255, 255, 255, 0.95);
            color: #667eea;
            border: none;
            padding: 14px 20px;
            border-radius: 8px;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            font-size: 14px;
            font-weight: 600;
            transition: all 0.2s ease;
            text-decoration: none;
        }
        
        .btn:hover {
            background: white;
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.2);
        }
        
        .btn:active {
            transform: translateY(0);
        }
        
        .btn .material-icons {
            font-size: 20px;
        }
        
        .btn.copied {
            background: #4caf50;
            color: white;
        }
        
        .status-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 16px;
        }
        
        .status-item {
            background: linear-gradient(135deg, #667eea15 0%, #764ba215 100%);
            border-radius: 12px;
            padding: 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .status-label {
            font-size: 15px;
            color: #666;
            font-weight: 500;
        }
        
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 8px 16px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .status-badge.online {
            background: #c8e6c9;
            color: #2e7d32;
        }
        
        .status-badge.offline {
            background: #ffcdd2;
            color: #c62828;
        }
        
        .status-badge .material-icons {
            font-size: 18px;
        }
        
        .metric-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 16px;
        }
        
        .metric-card {
            background: linear-gradient(135deg, #667eea15 0%, #764ba215 100%);
            border-radius: 12px;
            padding: 24px;
            text-align: center;
        }
        
        .metric-value {
            font-size: 36px;
            font-weight: 600;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin: 12px 0;
        }
        
        .metric-label {
            font-size: 12px;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 1px;
            font-weight: 500;
        }
        
        .footer {
            text-align: center;
            padding: 24px;
            color: white;
            font-size: 14px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 12px;
            backdrop-filter: blur(10px);
        }
        
        .loading {
            text-align: center;
            padding: 80px 20px;
            color: white;
        }
        
        .loading-spinner {
            border: 4px solid rgba(255, 255, 255, 0.3);
            border-top: 4px solid white;
            border-radius: 50%;
            width: 60px;
            height: 60px;
            animation: spin 1s linear infinite;
            margin: 0 auto 20px;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        @media (max-width: 768px) {
            .app-bar h1 {
                font-size: 28px;
            }
            
            .online-count {
                font-size: 72px;
            }
            
            .api-links {
                grid-template-columns: 1fr;
            }
            
            .api-buttons {
                flex-direction: column;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="app-bar">
            <h1>🚀 Hysteria UDP Manager</h1>
            <div class="subtitle">
                <span class="pulse-dot"></span>
                <span>Real-time Monitoring Dashboard</span>
            </div>
        </div>
        
        <div id="content">
            <div class="loading">
                <div class="loading-spinner"></div>
                <div>Loading dashboard...</div>
            </div>
        </div>
    </div>
    
    <script>
        async function fetchData() {
            try {
                const response = await fetch('/udpserver/system_info?t=' + Date.now());
                const data = await response.json();
                updateDashboard(data);
            } catch (error) {
                console.error('Error:', error);
                document.getElementById('content').innerHTML = `
                    <div class="loading">
                        <div>❌ Error loading data</div>
                    </div>
                `;
            }
        }
        
        function copyToClipboard(text, button) {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(() => {
                    showCopySuccess(button);
                }).catch(() => {
                    fallbackCopy(text, button);
                });
            } else {
                fallbackCopy(text, button);
            }
        }
        
        function fallbackCopy(text, button) {
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.select();
            
            try {
                document.execCommand('copy');
                showCopySuccess(button);
            } catch (err) {
                alert('Copy failed. URL: ' + text);
            }
            
            document.body.removeChild(textarea);
        }
        
        function showCopySuccess(button) {
            const originalHTML = button.innerHTML;
            button.innerHTML = '<span class="material-icons">check</span>Copied!';
            button.classList.add('copied');
            
            setTimeout(() => {
                button.innerHTML = originalHTML;
                button.classList.remove('copied');
            }, 2000);
        }
        
        function updateDashboard(data) {
            const hysteriaStatus = data.hysteria_status === 'online' ? 
                '<span class="status-badge online"><span class="material-icons">check_circle</span>Online</span>' :
                '<span class="status-badge offline"><span class="material-icons">cancel</span>Offline</span>';
            
            const webStatus = data.web_status === 'on' ? 
                '<span class="status-badge online"><span class="material-icons">check_circle</span>Active</span>' :
                '<span class="status-badge offline"><span class="material-icons">cancel</span>Inactive</span>';
            
            const apiJsonUrl = `http://${data.server_ip}/udpserver/online_app`;
            const apiTextUrl = `http://${data.server_ip}/udpserver/online`;
            
            document.getElementById('content').innerHTML = `
                <div class="card">
                    <div class="online-hero">
                        <div class="online-label">👥 Online Users</div>
                        <div class="online-count">${data.online}</div>
                    </div>
                </div>
                
                <div class="card">
                    <div class="card-title">
                        <span class="material-icons">info</span>
                        Server Information
                    </div>
                    <div class="info-grid">
                        <div class="info-item">
                            <div class="info-label">🌐 Domain</div>
                            <div class="info-value">${data.domain}</div>
                        </div>
                        <div class="info-item">
                            <div class="info-label">📡 Server IP</div>
                            <div class="info-value">${data.server_ip}</div>
                        </div>
                        <div class="info-item">
                            <div class="info-label">🔒 Obfuscation</div>
                            <div class="info-value">${data.obfuscation}</div>
                        </div>
                    </div>
                </div>
                
                <div class="card">
                    <div class="card-title">
                        <span class="material-icons">link</span>
                        API Endpoints
                    </div>
                    <div class="api-links">
                        <div class="api-link-card">
                            <div class="api-link-header">
                                <span class="material-icons">code</span>
                                <div class="api-link-title">📄 JSON API</div>
                            </div>
                            <div class="api-url-box">${apiJsonUrl}</div>
                            <div class="api-buttons">
                                <a href="${apiJsonUrl}" target="_blank" class="btn">
                                    <span class="material-icons">open_in_new</span>
                                    Open Link
                                </a>
                                <button class="btn" onclick="copyToClipboard('${apiJsonUrl}', this)">
                                    <span class="material-icons">content_copy</span>
                                    Copy Link
                                </button>
                            </div>
                        </div>
                        
                        <div class="api-link-card">
                            <div class="api-link-header">
                                <span class="material-icons">description</span>
                                <div class="api-link-title">📝 TEXT API</div>
                            </div>
                            <div class="api-url-box">${apiTextUrl}</div>
                            <div class="api-buttons">
                                <a href="${apiTextUrl}" target="_blank" class="btn">
                                    <span class="material-icons">open_in_new</span>
                                    Open Link
                                </a>
                                <button class="btn" onclick="copyToClipboard('${apiTextUrl}', this)">
                                    <span class="material-icons">content_copy</span>
                                    Copy Link
                                </button>
                            </div>
                        </div>
                    </div>
                </div>
                
                <div class="card">
                    <div class="card-title">
                        <span class="material-icons">power_settings_new</span>
                        Service Status
                    </div>
                    <div class="status-grid">
                        <div class="status-item">
                            <span class="status-label">Hysteria Server</span>
                            ${hysteriaStatus}
                        </div>
                        <div class="status-item">
                            <span class="status-label">Web Dashboard</span>
                            ${webStatus}
                        </div>
                    </div>
                </div>
                
                <div class="card">
                    <div class="card-title">
                        <span class="material-icons">analytics</span>
                        System Resources
                    </div>
                    <div class="metric-grid">
                        <div class="metric-card">
                            <div class="metric-label">CPU Cores</div>
                            <div class="metric-value">${data.cpu_cores}</div>
                        </div>
                        <div class="metric-card">
                            <div class="metric-label">CPU Usage</div>
                            <div class="metric-value">${data.cpu_usage}%</div>
                        </div>
                        <div class="metric-card">
                            <div class="metric-label">Memory Used</div>
                            <div class="metric-value">${data.mem_used}<small style="font-size: 14px;">MB</small></div>
                        </div>
                        <div class="metric-card">
                            <div class="metric-label">Memory Total</div>
                            <div class="metric-value">${data.mem_total}<small style="font-size: 14px;">MB</small></div>
                        </div>
                        <div class="metric-card">
                            <div class="metric-label">Memory Usage</div>
                            <div class="metric-value">${data.mem_percent}%</div>
                        </div>
                    </div>
                </div>
                
                <div class="footer">
                    <span class="material-icons" style="vertical-align: middle; font-size: 18px;">autorenew</span>
                    Auto-refresh every 3 seconds | Powered by Hysteria UDP
                </div>
            `;
        }
        
        fetchData();
        setInterval(fetchData, 3000);
    </script>
</body>
</html>
HTMLEOF
            
            chmod 644 "$WEB_DIR/index.html"
            
            # Create initial data files
            echo "0" > "$WEB_STATUS_FILE"
            echo "{\"onlines\":\"0\",\"limite\":\"$DEFAULT_LIMIT\"}" > "$WEB_APP_FILE"
            update_system_info
            
            # Set file permissions
            chmod 666 "$WEB_STATUS_FILE" "$WEB_APP_FILE" "$WEB_SYSTEM_FILE" 2>/dev/null
            
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx
                local server_ip=$(get_ipv4)
                echo -e "${GREEN}✓ Web server turned on${NC}"
                echo -e "${CYAN}Dashboard: http://${server_ip}/udpserver/${NC}"
                echo -e "${CYAN}API JSON:  http://${server_ip}/udpserver/online_app${NC}"
                echo -e "${CYAN}API TEXT:  http://${server_ip}/udpserver/online${NC}"
            else
                echo -e "${RED}✗ Nginx configuration test failed!${NC}"
                # If config test fails, remove faulty config to not break nginx
                rm -f /etc/nginx/sites-enabled/udp-status
            fi
        else
            echo -e "${YELLOW}Cancelled${NC}"
        fi
    fi
}

# =================================================================
# === Other original script functions (unchanged) ===
# =================================================================

change_domain() {
    echo -e "\n\e[1;34mEnter new domain:\e[0m"
    read -r domain
    jq ".server = \"$domain\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mDomain changed to $domain successfully\e[0m"
    restart_server
}

change_obfs() {
    echo -e "\n\e[1;34mEnter new obfuscation string:\e[0m"
    read -r obfs
    jq ".obfs.password = \"$obfs\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mObfuscation string changed to $obfs successfully\e[0m"
    restart_server
}

change_up_speed() {
    echo -e "\n\e[1;34mEnter new upload speed (Mbps):\e[0m"
    read -r up_speed
    jq ".up_mbps = $up_speed" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq ".up = \"$up_speed Mbps\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mUpload speed changed to $up_speed Mbps successfully\e[0m"
    restart_server
}

change_down_speed() {
    echo -e "\n\e[1;34mEnter new download speed (Mbps):\e[0m"
    read -r down_speed
    jq ".down_mbps = $down_speed" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq ".down = \"$down_speed Mbps\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "\e[1;32mDownload speed changed to $down_speed Mbps successfully\e[0m"
    restart_server
}

restart_server() {
    systemctl restart hysteria-server
    echo -e "\e[1;32mServer restarted successfully\e[0m"
}

uninstall_server() {
    echo -e "\n\e[1;34mUninstalling KSO UDP server...\e[0m"
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f "$SYSTEMD_SERVICE"
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR"
    rm -rf "$WEB_DIR"
    rm -f /usr/local/bin/hysteria
    echo -e "\e[1;32mKSO UDP server uninstalled successfully\e[0m"
}

show_banner() {
    echo -e "\e[1;36m---------------------------------------------"
    echo " KSO UDP"
    echo " (c) 2025 SHANVPN"
    echo " Telegram: @ovpnth"
    echo -e "---------------------------------------------\e[0m"
}

show_menu() {
    echo -e "\e[1;36m----------------------------"
    echo " KSO UDP"
    echo -e "----------------------------\e[0m"
    echo -e "\e[1;32m1. Add new user (with expiration date)"
    echo "2. Edit user (password / expiration date)"
    echo "3. Delete user"
    echo "4. Show all users (with passwords and expiration dates)"
    echo "5. Change domain"
    echo "6. Change obfuscation string"
    echo "7. Change upload speed"
    echo "8. Change download speed"
    echo "9. Restart server"
    echo "10. Toggle web server (dashboard)"
    echo "11. Uninstall server"
    echo -e "12. Exit\e[0m"
    echo -e "\e[1;36m----------------------------"
    echo -e "Please choose: \e[0m"
}

# =================================================================
# === Main Program ===
# =================================================================

# Run database initialization function
init_database

show_banner
while true; do
    show_menu
    read -r choice
    case $choice in
        1) add_user ;;
        2) edit_user ;;
        3) delete_user ;;
        4) show_users ;;
        5) change_domain ;;
        6) change_obfs ;;
        7) change_up_speed ;;
        8) change_down_speed ;;
        9) restart_server ;;
        10) toggle_web_server ;;
        11) uninstall_server; exit 0 ;;
        12) exit 0 ;;
        *) echo -e "\e[1;31mInvalid option. Please try again\e[0m" ;;
    esac
done
