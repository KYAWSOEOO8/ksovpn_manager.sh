#!/usr/bin/env bash
set -e
DOMAIN="marippp.com"
PROTOCOL="udp"
UDP_PORT=":36712"
OBFS="ksovpn"
CONFIG_DIR="/etc/hysteria"
USER_DB="$CONFIG_DIR/udpusers.db"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"

mkdir -p "$CONFIG_DIR"
apt update && apt install -y sqlite3 curl

# Manager Script Section
cat << 'EOF' > /usr/local/bin/ksovpn_manager.sh
#!/usr/bin/env bash
USER_DB="/etc/hysteria/udpusers.db"
while true; do
    clear
    echo "=== KSOVPN MANAGER ==="
    echo "1) Add User  2) Delete User  3) List  0) Exit"
    read -p "Select: " opt
    case $opt in
        1) read -p "User: " u; read -p "Pass: " p; sqlite3 "$USER_DB" "INSERT INTO users VALUES ('$u', '$p');"; systemctl restart hysteria-server; sleep 1 ;;
        3) sqlite3 "$USER_DB" "SELECT * FROM users;"; read -p "Enter..." ;;
        0) exit 0 ;;
    esac
done
EOF

chmod +x /usr/local/bin/ksovpn_manager.sh
ln -sf /usr/local/bin/ksovpn_manager.sh /usr/local/bin/ksovpn

# Hysteria Install
curl -L "https://github.com/apernet/hysteria/releases/download/v1.3.5/hysteria-linux-amd64" -o "$EXECUTABLE_INSTALL_PATH"
chmod +x "$EXECUTABLE_INSTALL_PATH"
sqlite3 "$USER_DB" "CREATE TABLE IF NOT EXISTS users (username TEXT, password TEXT);"

echo "Installation Complete! Type 'ksovpn' to start."

