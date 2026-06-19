#!/bin/bash

# Function to print characters with delay
print_with_delay() {
    text="$1"
    delay="$2"
    for ((i = 0; i < ${#text}; i++)); do
        echo -n "${text:$i:1}"
        sleep "$delay"
    done
    echo
}

# Introduction animation
echo ""


# Ensure root
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 用户身份运行。" 
   exit 1
fi

# Check for and install required packages
install_required_packages() {
    REQUIRED_PACKAGES=("curl" "certbot")
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            apt-get update > /dev/null 2>&1
            apt-get install -y "$pkg" > /dev/null 2>&1
        fi
    done
}

# Function to update Hysteria binary
update_hysteria() {
    echo "将 Hysteria 更新到最新版本..."
    bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh) > /dev/null 2>&1
    systemctl restart hysteria-server
    echo "Hysteria 已成功更新"
}

# Check if the directory /etc/hysteria already exists
if [ -d "/etc/hysteria" ] && [ -f "/etc/hysteria/config.yaml" ]; then
    echo "Hysteria 已经安装"
    echo ""
    echo "--------------------"
    echo ""
    echo "1) 重新安装"
    echo ""
    echo "2) 更改配置"
    echo ""
    echo "3) 更新Hysteria"
    echo ""
    echo "4) 卸载Hysteria"
    echo ""
    echo "5) 查看配置"
    echo ""
    read -r -p "请选择" choice
    case $choice in
        1)
            # Reinstall
            systemctl stop hysteria-server
            systemctl disable hysteria-server > /dev/null 2>&1
            rm -rf /etc/hysteria
            rm -rf /etc/systemd/system/hysteria-server.service.d
            systemctl daemon-reload
            ;;
        2)
            # Modify
            # Read current settings from config
            current_port=$(grep -oP 'listen: :\K\d+' /etc/hysteria/config.yaml || echo "443")
            current_password=$(awk '/^auth:/{f=1; next} f && /^[^ ]/{f=0} f && /password:/{print $2; exit}' /etc/hysteria/config.yaml)
            current_domain=$(grep -oP 'cert: .*/live/\K[^/]+' /etc/hysteria/config.yaml || echo "$domain")
            current_obfs_password=$(awk '/^obfs:/{f=1; next} f && /^[^ ]/{f=0} f && /password:/{print $2; exit}' /etc/hysteria/config.yaml)
            
            echo ""
            read -r -p "请输入端口（回车默认） [$current_port]): " new_port
            [ -z "$new_port" ] && new_port=$current_port
            echo ""
            read -r -p "请输入密码 （回车默认）[$current_password]): " new_password
            [ -z "$new_password" ] && new_password=$current_password
            echo ""

            # Obfs modification
            if [ -n "$current_obfs_password" ]; then
                echo "混淆（Salamander）功能目前已启用。 (password: $current_obfs_password)"
                read -r -p "保持 obfs 启用? (y/n, default: y): " keep_obfs
                if [ "$keep_obfs" = "n" ] || [ "$keep_obfs" = "N" ]; then
                    new_obfs_password=""
                else
                    read -r -p "请输入obfs密码(回车默认): " new_obfs_password
                    [ -z "$new_obfs_password" ] && new_obfs_password=$current_obfs_password
                fi
            else
                echo "混淆（Salamander）功能目前已禁用。"
                read -r -p "启用 obfs? (y/n, default: n): " enable_obfs
                if [ "$enable_obfs" = "y" ] || [ "$enable_obfs" = "Y" ]; then
                    read -r -p "请输入obfs密码(回车默认): " new_obfs_password
                    [ -z "$new_obfs_password" ] && new_obfs_password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
                else
                    new_obfs_password=""
                fi
            fi
            echo ""

            # Parse current routing configuration
            current_routing="2"
            if grep -q "mode: 4" /etc/hysteria/config.yaml && ! grep -q "mode: 46" /etc/hysteria/config.yaml; then
                current_routing="3"
            elif ! grep -q "mode:" /etc/hysteria/config.yaml; then
                current_routing="1"
            fi

            echo ""
            echo "选择出站路由模式:"
            echo "1) 默认(Dual-stack auto)"
            echo "2) 首选 IPv4（推荐用于 IPv6 损坏/缓慢的 VPS）"
            echo "3) 仅强制使用 IPv4"
            read -r -p "请选择 [1-3, 默认: $current_routing]: " route_choice
            [ -z "$route_choice" ] && route_choice=$current_routing

            resolver_yaml=""
            outbounds_yaml=""

            if [ "$route_choice" = "2" ]; then
                resolver_yaml="
resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53"
                outbounds_yaml="
outbounds:
  - name: direct
    type: direct
    direct:
      mode: 46"
            elif [ "$route_choice" = "3" ]; then
                resolver_yaml="
resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53"
                outbounds_yaml="
outbounds:
  - name: direct
    type: direct
    direct:
      mode: 4"
            fi

            # Rebuild config.yaml
            current_cert=$(grep 'cert:' /etc/hysteria/config.yaml | awk '{print $2}')
            current_key=$(grep 'key:' /etc/hysteria/config.yaml | awk '{print $2}')

            config_yaml="listen: :$new_port
tls:
  cert: $current_cert
  key: $current_key
auth:
  type: password
  password: $new_password"

            if [ -n "$new_obfs_password" ]; then
                config_yaml="$config_yaml
obfs:
  type: salamander
  salamander:
    password: $new_obfs_password"
            fi

            config_yaml="$config_yaml$resolver_yaml$outbounds_yaml"

            echo "$config_yaml" > /etc/hysteria/config.yaml

            # Restart the hysteria service
            systemctl restart hysteria-server

            # Print client configs
            echo "v2rayN client config:"
            v2rayN_config="server: $domain:$new_port
auth: $new_password
tls:
  sni: $current_domain
  insecure: false
fastOpen: true
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809"
            if [ -n "$new_obfs_password" ]; then
                v2rayN_config="server: $domain:$new_port
auth: $new_password
obfs:
  type: salamander
  salamander:
    password: $new_obfs_password
tls:
  sni: $current_domain
  insecure: false
fastOpen: true
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809"
            fi
            echo "$v2rayN_config"
            echo ""

            echo "-----链接-----"
            if [ -n "$new_obfs_password" ]; then
                nekobox_url="hysteria2://$new_password@$domain:$new_port/?insecure=0&sni=$domain&obfs=salamander&obfs-password=$new_obfs_password#hy2"
            else
                nekobox_url="hysteria2://$new_password@$domain:$new_port/?insecure=0&sni=$domain#hy2"
            fi
            echo "$nekobox_url"
            echo ""
            exit 0
            ;;
        3)
            # Update
            update_hysteria
            exit 0
            ;;
        4)
            # Uninstall
            systemctl stop hysteria-server
            systemctl disable hysteria-server > /dev/null 2>&1
            rm -rf /etc/hysteria
            rm -f /usr/local/bin/hysteria
            rm -f /etc/systemd/system/hysteria-server.service
            rm -f /etc/systemd/system/hysteria-server@.service
            rm -rf /etc/systemd/system/hysteria-server.service.d
            systemctl daemon-reload
            echo "Hysteria 卸载完成！"
            echo ""
            exit 0
            ;;
        5)
            # Show current link
            current_port=$(grep -oP 'listen: :\K\d+' /etc/hysteria/config.yaml || echo "443")
            current_password=$(awk '/^auth:/{f=1; next} f && /^[^ ]/{f=0} f && /password:/{print $2; exit}' /etc/hysteria/config.yaml)
            current_domain=$(grep -oP 'cert: .*/live/\K[^/]+' /etc/hysteria/config.yaml || echo "$domain")
            current_obfs_password=$(awk '/^obfs:/{f=1; next} f && /^[^ ]/{f=0} f && /password:/{print $2; exit}' /etc/hysteria/config.yaml)

            echo ""
            echo "v2rayN 客户端配置"
            v2rayN_config="server: $domain:$current_port
auth: $current_password
tls:
  sni: $current_domain
  insecure: false
fastOpen: true
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809"
            if [ -n "$current_obfs_password" ]; then
                v2rayN_config="server: $domain:$current_port
auth: $current_password
obfs:
  type: salamander
  salamander:
    password: $current_obfs_password
tls:
  sni: $current_domain
  insecure: false
fastOpen: true
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809"
            fi
            echo "$v2rayN_config"
            echo ""

            echo "-----链接-----"
            if [ -n "$current_obfs_password" ]; then
                nekobox_url="hysteria2://$current_password@$domain:$current_port/?insecure=0&sni=$domain&obfs=salamander&obfs-password=$current_obfs_password#hy2"
            else
                nekobox_url="hysteria2://$current_password@$domain:$current_port/?insecure=0&sni=$domain#hy2"
            fi
            echo "$nekobox_url"
            echo ""
            exit 0
            ;;
        *)
            echo "选项无效。"
            exit 1
            ;;
    esac
fi

# Install required packages if not already installed
install_required_packages

# Step 1: Install Hysteria using official script
echo "安装 Hysteria..."
bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh) > /dev/null 2>&1

# Step 2: Certbot domain setup
echo ""
echo "Hysteria 需要有效的 SSL 证书。"
echo "请确保您的域名 DNS A 记录指向此服务器的 IP 地址。"
echo "如果您还没有 Let's Encrypt 证书，请确保端口 80 已打开，以便获取证书"
read -r -p "请输入你的域名 (例如vpn.example.com): " domain
if [ -z "$domain" ]; then
    echo "域名为必填项退出"
    exit 1
fi

# Check for existing certificates in common locations dynamically
cert_path=""
key_path=""

echo "正在搜索现有证书 $domain..."

# Explicit paths where cert and key might be in different directories or named exactly as the domain
explicit_certs=(
    "/etc/letsencrypt/live/$domain/fullchain.pem"
    "/etc/ssl/certs/$domain.crt"
    "/etc/ssl/certs/$domain.pem"
    "/etc/nginx/ssl/$domain.crt"
    "/root/cert/$domain.crt"
    "/root/certs/$domain.crt"
    "/root/cert/$domain/fullchain.pem"
)
explicit_keys=(
    "/etc/letsencrypt/live/$domain/privkey.pem"
    "/etc/ssl/private/$domain.key"
    "/etc/ssl/private/$domain.key"
    "/etc/nginx/ssl/$domain.key"
    "/root/cert/$domain.key"
    "/root/certs/$domain.key"
    "/root/cert/$domain/privkey.pem"
)

for i in "${!explicit_certs[@]}"; do
    if [ -f "${explicit_certs[$i]}" ] && [ -f "${explicit_keys[$i]}" ]; then
        cert_path="${explicit_certs[$i]}"
        key_path="${explicit_keys[$i]}"
        break
    fi
done

# If not found in explicit paths, search dynamically for a directory matching the domain
if [ -z "$cert_path" ] || [ -z "$key_path" ]; then
    # find directories up to 5 levels deep in common root locations
    search_dirs=$(find /etc /root /home -maxdepth 5 -type d \( -name "$domain" -o -name "${domain}_ecc" \) 2>/dev/null)
    
    for dir in $search_dirs; do
        possible_c=( "fullchain.pem" "fullchain.cer" "$domain.cer" "$domain.crt" "cert.pem" "cert.crt" )
        possible_k=( "privkey.pem" "$domain.key" "private.key" "key.pem" "cert.key" )
        
        found_c=""
        found_k=""
        
        for c in "${possible_c[@]}"; do
            if [ -f "$dir/$c" ]; then
                found_c="$dir/$c"
                break
            fi
        done
        
        for k in "${possible_k[@]}"; do
            if [ -f "$dir/$k" ]; then
                found_k="$dir/$k"
                break
            fi
        done
        
        if [ -n "$found_c" ] && [ -n "$found_k" ]; then
            cert_path="$found_c"
            key_path="$found_k"
            break
        fi
    done
fi

if [ -n "$cert_path" ] && [ -n "$key_path" ]; then
    echo "找到现有证书 $domain at $cert_path"
else
    echo "未找到现有证书。正在生成证书..."
    read -r -p "请输入您的邮箱: " email
    if [ -z "$email" ]; then
        certbot_email_args=("--register-unsafely-without-email")
    else
        certbot_email_args=("-m" "$email")
    fi

    # Obtain certificate
    echo "运行 Certbot 获取证书..."
    certbot certonly --standalone -d "$domain" --agree-tos "${certbot_email_args[@]}" --non-interactive

    if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
        cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
        key_path="/etc/letsencrypt/live/$domain/privkey.pem"
    else
        echo "证书生成失败"
        exit 1
    fi
fi

# Step 3: Prompt user for input
echo ""
read -r -p "请输入端口号（回车默认）: " port
[ -z "$port" ] && port=$((RANDOM + 10000))

echo ""
read -r -p "请输入密码（回车默认）: " password
[ -z "$password" ] && password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)

# Step 3.5: Obfuscation (Salamander)
echo ""
read -r -p "启用 Salamander 混淆功能？ (y/n, 默认: n): " enable_obfs
obfs_password=""
if [ "$enable_obfs" = "y" ] || [ "$enable_obfs" = "Y" ]; then
    read -r -p "请输入obfs密码 (回车默认): " obfs_password
    [ -z "$obfs_password" ] && obfs_password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
fi

# Step 3.6: Outbound Routing Mode
echo ""
echo "选择出站路由模式:"
echo "1) 默认 (Dual-stack auto)"
echo "2) 优先选择 IPv4（推荐用于 IPv6 连接不稳定/速度慢的 VPS） [Default]"
echo "3) 仅强制使用 IPv4"
read -r -p "请选择 [1-3, default: 2]: " route_choice
[ -z "$route_choice" ] && route_choice="2"

resolver_yaml=""
outbounds_yaml=""

if [ "$route_choice" = "2" ]; then
    resolver_yaml="
resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53"
    outbounds_yaml="
outbounds:
  - name: direct
    type: direct
    direct:
      mode: 46"
elif [ "$route_choice" = "3" ]; then
    resolver_yaml="
resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53"
    outbounds_yaml="
outbounds:
  - name: direct
    type: direct
    direct:
      mode: 4"
fi

# Step 4: Create configuration
mkdir -p /etc/hysteria
config_yaml="listen: :$port
tls:
  cert: $cert_path
  key: $key_path
auth:
  type: password
  password: $password"

if [ -n "$obfs_password" ]; then
    config_yaml="$config_yaml
obfs:
  type: salamander
  salamander:
    password: $obfs_password"
fi

config_yaml="$config_yaml$resolver_yaml$outbounds_yaml"

echo "$config_yaml" > /etc/hysteria/config.yaml

# Step 5: Override systemd user to root to access certs
echo "正在配置 systemd 服务..."
mkdir -p /etc/systemd/system/hysteria-server.service.d/
cat > /etc/systemd/system/hysteria-server.service.d/override.conf <<EOL
[Service]
User=root
Group=root
EOL

systemctl daemon-reload
systemctl enable hysteria-server > /dev/null 2>&1
systemctl restart hysteria-server

# Step 6: Generate and print client config files
echo ""
echo "======================================"
echo "Hysteria 2 安装完成"
echo "======================================"
echo ""
echo "v2rayN 客户端配置"
echo ""
v2rayN_config="server: $domain:$port
auth: $password
tls:
  sni: $current_domain
  insecure: false
fastOpen: true
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809"
if [ -n "$obfs_password" ]; then
    v2rayN_config="server: $domain:$port
auth: $password
obfs:
  type: salamander
  salamander:
    password: $obfs_password
tls:
  sni: $current_domain
  insecure: false
fastOpen: true
socks5:
  listen: 127.0.0.1:10808
http:
  listen: 127.0.0.1:10809"
fi
echo "$v2rayN_config"
echo ""
echo "-----链接-----"
echo ""
if [ -n "$obfs_password" ]; then
    nekobox_url="hysteria2://$password@$domain:$port/?insecure=0&sni=$domain&obfs=salamander&obfs-password=$obfs_password#hy2"
else
    nekobox_url="hysteria2://$password@$domain:$port/?insecure=0&sni=$domain#hy2"
fi
echo "$nekobox_url"
echo ""
