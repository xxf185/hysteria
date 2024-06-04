#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"
# 颜色定义
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"

# 相应的函数

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

blue(){
    echo -e "${BLUE}\033[01m$1${PLAIN}"
}

purple(){
    echo -e "${PURPLE}\033[01m$1${PLAIN}"
}

cyan(){
    echo -e "${CYAN}\033[01m$1${PLAIN}"
}

DISTRO=$(lsb_release -is)

case $DISTRO in
  Ubuntu|Debian)
    PACKAGE_MANAGER="apt"
  ;;
  CentOS|RedHat|Fedora)
    PACKAGE_MANAGER="yum"
  ;;
  *)
    echo "Unsupported distro"
    exit 1
  ;;  
esac

if ! command -v curl > /dev/null; then
  sudo $PACKAGE_MANAGER update
  sudo $PACKAGE_MANAGER install -y curl
fi

realip(){
    ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
}

inst_cert(){
    green "选择证书申请方式:"
    echo ""
    echo -e " ${YELLOW}1.使用 ACME（默认）${PLAIN} "
    echo -e " ${YELLOW}2.使用自签名证书 (OpenSSL)${PLAIN} "
    echo -e " ${YELLOW}3.使用自定义证书${PLAIN} "
    echo ""
    read -rp "选择 [1-3]: " certInput

    # If no input is provided, default to 1 (Apply using ACME)
    if [[ -z "$certInput" ]]; then
        certInput=1
    fi
    if [[ $certInput == 1 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"

        chmod -R 777 /root # 让 Hysteria 主程序访问到 /root 目录

        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "Existing certificate detected for domain: $domain, applying"
            hy_domain=$domain
        else
            WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
                wg-quick down wgcf >/dev/null 2>&1
                systemctl stop warp-go >/dev/null 2>&1
                realip
                wg-quick up wgcf >/dev/null 2>&1
                systemctl start warp-go >/dev/null 2>&1
            else
                realip
            fi
            
            read -p "输入域名申请证书: " domain
            [[ -z $domain ]] && red "输入错误" && exit 1
            green "域名:$domain" && sleep 1
            domainIP=$(curl -sm8 ipget.net/?ip="${domain}")
            if [[ $domainIP == $ip ]]; then
            sudo $PACKAGE_MANAGER install -y curl wget sudo socat openssl
            
            if [ $DISTRO = "CentOS" ]; then
              sudo $PACKAGE_MANAGER install -y cronie
              systemctl start crond
              systemctl enable crond  
            else
              sudo $PACKAGE_MANAGER install -y cron 
              systemctl start cron
              systemctl enable cron
            fi
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
                source ~/.bashrc
                bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                if [[ -n $(echo $ip | grep ":") ]]; then
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
                else
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
                fi
                bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
                if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]]; then
                    echo $domain > /root/ca.log
                    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                    green "证书生成成功并保存在 /root 目录中。"
                    yellow "公钥路径: /root/cert.crt"
                    yellow "私钥路径: /root/private.key"
                    hy_domain=$domain
                fi
            else
                red "域名无法解析"
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -p "输入公钥(CRT) path: " cert_path
        yellow "公钥路径: $cert_path"
        read -p "输入私钥 (KEY) path: " key_path
        yellow "私钥路径: $key_path"
        read -p "输入证书域名: " domain
        yellow "证书域名: $domain"
        hy_domain=$domain
    else
        green "使用自签名证书 (OpenSSL)"
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
        chmod 777 /etc/hysteria/cert.crt
        chmod 777 /etc/hysteria/private.key
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port(){
    iptables -t nat -F PREROUTING >/dev/null 2>&1

    read -p "输入port [1-65535] (默认为随机): " port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} PORT $port ${PLAIN} 已占用.请重试不同的端口"
            read -p "输入port [1-65535] (默认为随机): " port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
        fi
    done


    yellow "port:$port"
    inst_jump
}

inst_jump() {
    green "Hysteria 2端口使用模式:"
    echo ""
    echo -e " ${YELLOW}1.单端口模式 (默认)${PLAIN}"
    echo -e " ${YELLOW}2.端口范围跳跃${PLAIN}"
    echo ""
    read -rp "选择 [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        read -p "输入范围的起始端口（建议 10000-65535）: " firstport
        read -p "输入范围的结束端口（必须大于起始端口）: " endport
        while [[ $firstport -ge $endport ]]; do
            red "起始端口必须小于结束端口。 请重新输入起始端口和结束端口。"
            read -p "输入范围的起始端口（建议 10000-65535）：" firstport
            read -p "输入范围的结束端口（建议10000-65535，必须大于起始端口）: " endport
        done
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        netfilter-persistent save >/dev/null 2>&1
    else
        red "继续单端口模式"
    fi
}


inst_pwd() {
    read -p "输入密码（默认随机）： " auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "密码: $auth_pwd"
}

inst_site() {
    read -rp "输入伪装网站 URL（无需 https://）[默认 SEGA Japan]： " proxysite
    [[ -z $proxysite ]] && proxysite="maimai.sega.jp"
    yellow "伪装网站: $proxysite"
}


insthysteria(){

    if netstat -tuln | grep -q ":80 "; then
        echo "80 端口已被占用退出..."
        exit 1
    fi

    warpv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    warpv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $warpv4 =~ on|plus || $warpv6 =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
        realip
        systemctl start warp-go >/dev/null 2>&1
        wg-quick up wgcf >/dev/null 2>&1
    else
        realip
    fi

    # if [ $DISTRO = "CentOS" ]; then
    #   sudo $PACKAGE_MANAGER install -y curl wget sudo qrencode procps iptables-persistent netfilter-persistent
    # else
    #   sudo $PACKAGE_MANAGER update 
    #   sudo $PACKAGE_MANAGER install -y curl wget sudo qrencode procps iptables-persistent netfilter-persistent
    # fi

    if [ $DISTRO = "CentOS" ]; then
      sudo $PACKAGE_MANAGER install -y curl wget sudo qrencode procps iptables-persistent net-tools
    else
      sudo $PACKAGE_MANAGER update
      sudo $PACKAGE_MANAGER install -y curl wget sudo qrencode procps iptables-persistent net-tools  
    fi


    # Install Hysteria 2
    bash <(curl -fsSL https://github.com/xxf185/git/releases/latest/download/install_server.sh)

    if [[ -f "/usr/local/bin/hysteria" ]]; then
        green "安装成功"
    else
        red "安装失败"
        exit 1
    fi

    # 询问用户 Hysteria 配置
    inst_cert
    inst_port
    inst_pwd
    inst_site

    # 设置 Hysteria 配置文件
    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $auth_pwd

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF

    # 确定最终入站端口范围
    if [[ -n $firstport ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port=$port
    fi

    # Check if inst_cert is set to "echo -e " ${GREEN}1.${PLAIN} Use ACME (default)""
    if [[ $certInput == 1 ]]; then
        last_ip=$domain
    else
        # Add brackets to IPv6 addresses
        if [[ -n $(echo $ip | grep ":") ]]; then
            last_ip="[$ip]"
        else
            last_ip=$ip
        fi
    fi

    mkdir /root/hy

    url="hysteria2://$auth_pwd@$last_ip:$last_port/?insecure=1&sni=$hy_domain#hy2"
    echo $url > /root/hy/url.txt
    nohopurl="hysteria2://$auth_pwd@$last_ip:$port/?insecure=1&sni=$hy_domain#hy2"
    echo $nohopurl > /root/hy/url-nohop.txt
    surge_format="TEST HY2 = hysteria2, $last_ip, $last_port, password=$auth_pwd, sni=$hy_domain, download-bandwidth=1000, skip-cert-verify=true"
    echo $surge_format > /root/hy/HY4SURGE.txt

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server
    if [[ -n $(systemctl status hysteria-server 2>/dev/null | grep -w active) && -f '/etc/hysteria/config.yaml' ]]; then
        green "Hysteria 2 启动成功"
    else
        red "Hysteria 2 启动失败" && exit 1
    fi
    blue ""
    green "Hysteria 2 安装成功"
    green 
    green "Hysteria 2 配置文件 (path: /root/hy/url.txt):"
    yellow "$(cat /root/hy/url.txt)"
    green 
    green "Hysteria 2 单端口配置文件(path: /root/hy/url-nohop.txt):"
    yellow "$(cat /root/hy/url-nohop.txt)"
    green 
    green "Hysteria 2 SURGE 配置文件 (path: /root/hy/HY4SURGE.txt):"
    yellow "$(cat /root/hy/HY4SURGE.txt)"
}

unsthysteria(){
    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy /root/hysteria.sh
    iptables -t nat -F PREROUTING >/dev/null 2>&1
    netfilter-persistent save >/dev/null 2>&1

    green "卸载完成"
}

starthysteria(){
    systemctl start hysteria-server
    systemctl enable hysteria-server >/dev/null 2>&1
}

stophysteria(){
    systemctl stop hysteria-server
    systemctl disable hysteria-server >/dev/null 2>&1
}

hysteriaswitch(){
    echo ""
    echo -e " ${YELLOW}1.启动${PLAIN} "
    echo -e " ${YELLOW}2.停止${PLAIN} "
    echo -e " ${YELLOW}3.重启${PLAIN} "
    echo ""
    read -rp "选择 [0-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        * ) exit 1 ;;
    esac
}

changeport(){
    oldport=$(cat /etc/hysteria/config.yaml 2>/dev/null | sed -n 1p | awk '{print $2}' | awk -F ":" '{print $2}')
    
    read -p "输入端口 [1-65535]（默认随机）: " port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)

    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} PORT $port ${PLAIN} IS ALREADY IN USE BY ANOTHER APPLICATION. PLEASE CHOOSE A DIFFERENT PORT!"
            read -p "SET Hysteria 2 PORT [1-65535] (PRESS ENTER FOR RANDOM PORT): " port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
        fi
    done

    sed -i "1s#$oldport#$port#g" /etc/hysteria/config.yaml
    sed -i "1s#$oldport#$port#g" /root/hy/HY4SURGE.txt

    stophysteria && starthysteria

    green "端口已更新: $port"
    showconf
}

changepasswd(){
    oldpasswd=$(cat /etc/hysteria/config.yaml 2>/dev/null | sed -n 15p | awk '{print $2}')

    read -p "输入密码（默认随机）: " passwd
    [[ -z $passwd ]] && passwd=$(date +%s%N | md5sum | cut -c 1-8)

    sed -i "1s#$oldpasswd#$passwd#g" /etc/hysteria/config.yaml
    sed -i "1s#$oldpasswd#$passwd#g" /root/hy/HY4SURGE.txt

    stophysteria && starthysteria

    green "密码已更新: $auth_pwd"
    showconf
}

change_cert(){
    old_cert=$(cat /etc/hysteria/config.yaml | grep cert | awk -F " " '{print $2}')
    old_key=$(cat /etc/hysteria/config.yaml | grep key | awk -F " " '{print $2}')
    old_hydomain=$(cat /root/hy/HY4SURGE.txt | grep sni | awk '{print $2}')

    inst_cert

    sed -i "s!$old_cert!$cert_path!g" /etc/hysteria/config.yaml
    sed -i "s!$old_key!$key_path!g" /etc/hysteria/config.yaml
    sed -i "6s/$old_hydomain/$hy_domain/g" /root/hy/HY4SURGE.txt

    stophysteria && starthysteria

    green "证书已更新"
    showconf
}

changeproxysite(){
    oldproxysite=$(cat /etc/hysteria/config.yaml | grep url | awk -F " " '{print $2}' | awk -F "https://" '{print $2}')
    
    inst_site

    sed -i "s#$oldproxysite#$proxysite#g" /etc/caddy/Caddyfile

    stophysteria && starthysteria

    green "伪装网站已更新: $proxysite"
}

changeconf() {
    green ""
    echo -e " ${YELLOW}1.更改端口${PLAIN} "
    echo -e " ${YELLOW}2.更改密码${PLAIN} "
    echo -e " ${YELLOW}3.更改证书类型${PLAIN} "
    echo -e " ${YELLOW}4.更改伪装网站${PLAIN} "
    echo ""
    read -p " 选择 [1-4]: " confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) change_cert ;;
        4 ) changeproxysite ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    green 
    green  "------------------链接------------------"
    yellow "$(cat /root/hy/url.txt)"
    green 
    green  "------------------单端口链接------------------"
    yellow "$(cat /root/hy/url-nohop.txt)"
    green 
    green  "------------------SURGE链接------------------"
    yellow "$(cat /root/hy/HY4SURGE.txt)"
}

update_core(){
    # ReInstall Hysteria 2
    bash <(curl -fsSL https://github.com/xxf185/hysteria2/releases/download/v1.0/install_server.sh)

}

menu() {
    clear
    echo ""
    echo -e " ${YELLOW}-----Hysteria2一键脚本-----${PLAIN}"
    echo ""
    echo -e " ${YELLOW}1. 安装${PLAIN}"
    echo -e " ${YELLOW}2. 卸载${PLAIN}"
    echo -e " ${YELLOW}3. 启动.停止.重启${PLAIN}"
    echo -e " ${YELLOW}4. 修改配置${PLAIN}"
    echo -e " ${YELLOW}5. 查看配置${PLAIN}"
    echo -e " ${YELLOW}6. 升级core${PLAIN}"
    echo -e " ${YELLOW}0. 退出${PLAIN}"
    echo ""
    read -rp "选择 [0-5]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        6 ) update_core ;;
        0 ) exit 1 ;;
        * ) menu ;;
    esac
}

menu
