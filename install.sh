#!/usr/bin/env bash
# https://github.com/xxf185/hysteria
# Hysteria2一键管理脚本：安装/更新/查看/更改端口/更改密码/删除
# 适配 Debian/Ubuntu (apt) 与 CentOS/RHEL/Alma/Rocky (yum/dnf)

set -euo pipefail

SERVICE="hysteria-server.service" # Hysteria2服务
CONF_DIR="/etc/hysteria" # 配置目录
CONF_FILE="${CONF_DIR}/config.yaml" # 主配置文件
CLIENT_FILE="${CONF_DIR}/hyclient.txt" # 文本清单
TZ_DEFAULT="Asia/Shanghai" # 默认时区
SHELL_VERSION="1.0" # 版本
H2_SNI="www.bing.com"  # 伪装域名
H2_ALIASES="hy2" # 别名

# 字体颜色配置
Font="\033[0m"

Black="\033[30m"   # 黑色
Red="\033[31m"     # 红色
Green="\033[32m"   # 绿色
Yellow="\033[33m"  # 黄色
Blue="\033[34m"    # 蓝色
Magenta="\033[35m" # 紫/洋红
Cyan="\033[36m"    # 青
White="\033[37m"   # 白色

BBlack="\033[90m"
BRed="\033[91m"
BGreen="\033[92m"
BYellow="\033[93m"
BBlue="\033[94m"
BMagenta="\033[95m"
BCyan="\033[96m"
BWhite="\033[97m"

BlackBG="\033[40m"
RedBG="\033[41m"
GreenBG="\033[42m"
YellowBG="\033[43m"
BlueBG="\033[44m"
MagentaBG="\033[45m"
CyanBG="\033[46m"
WhiteBG="\033[47m"

Bold="\033[1m"
Dim="\033[2m"
Italic="\033[3m"
Underline="\033[4m"
Blink="\033[5m"
Reverse="\033[7m"
Hidden="\033[8m"
Strike="\033[9m"

OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

center() {
  local s="$1"
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)

  local noansi
  noansi=$(printf '%b' "$s" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g')

  local width
  width=$(LC_ALL=C.UTF-8 awk -v str="$noansi" '
    BEGIN{
      n = split(str, a, "")
      w = 0
      for(i=1;i<=n;i++){
        c = a[i]
        if (c ~ /[ -~]/) w += 1
        else             w += 2
      }
      print w
    }')

  local pad=$(( (cols - width) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%b\n" "$pad" "" "$s"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl gawk openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl gawk openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl gawk openssl
  else
    echo "未识别的包管理器，请手动安装 curl、gawk、openssl 后重试"
    exit 1
  fi
}

# -------- 安装状态检测 --------
service_installed() { systemctl status "${SERVICE}" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "${SERVICE}"; }

is_installed() {
  # 满足：存在二进制 或 服务可用，并且存在配置文件，认为已安装
  if { has_cmd hysteria || service_installed; } && [[ -f "${CONF_FILE}" ]]; then
    return 0
  fi
  return 1
}

status_text() {
  if is_installed; then
    if service_active; then
      echo -e "${BGreen}已安装（运行中）${Font}"
    else
      echo -e "${BYellow}已安装（已停止）${Font}"
    fi
  else
    echo -e "${BRed}未安装${Font}"
  fi
}

get_ip() {
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip4}" ]]; then
    echo "${ip4}"
    return
  fi
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip6}" ]]; then
    echo "${ip6}"
    return
  fi
  curl -s https://api.ipify.org || true
}

random_port() { shuf -i 2000-65000 -n 1; }

# 确保端口是数字并且在合法范围内
valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 检查端口是否被占用
is_port_free() {
  local port="$1"
  ss -tuln | grep ":$port " >/dev/null 2>&1
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi

    # 验证端口是否合法
    if ! valid_port "$input"; then
      echo "端口不合法：$input，请输入一个有效的端口（1-65535）。"
      continue
    fi

    # 检查端口是否被占用
    if is_port_free "$input"; then
      echo "端口 $input 已被占用，请选择另一个端口。"
      continue
    fi

    # 如果端口合法且未被占用，退出循环
    echo "$input"
    break
  done
}

gen_password() { cat /proc/sys/kernel/random/uuid; }

ensure_cert() {
  mkdir -p "${CONF_DIR}"
  if [[ ! -f "${CONF_DIR}/server.key" || ! -f "${CONF_DIR}/server.crt" ]]; then
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "${CONF_DIR}/server.key" \
      -out "${CONF_DIR}/server.crt" -subj "/CN=${H2_SNI}" -days 36500
    chown hysteria:hysteria "${CONF_DIR}/server.key" "${CONF_DIR}/server.crt" || true
  fi
}

write_config() {
  # 参数：端口 密码
  local port="$1" pass="$2"
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" <<EOF
listen: :${port}
tls:
  cert: ${CONF_DIR}/server.crt
  key: ${CONF_DIR}/server.key

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: https://${H2_SNI}
    rewriteHost: true
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
}

client_export() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    echo "未找到 ${CONF_FILE}"
    return 1
  fi
  local port pass ip link
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONF_FILE}")
  if [[ -z "${port}" ]]; then
    port=$(awk '/^[[:space:]]*listen:/ { if (match($0, /:([0-9]+)[[:space:]]*$/, a)) print a[1] }' "${CONF_FILE}")
  fi
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONF_FILE}")
  ip=$(get_ip)
  link="${pass}@${ip}:${port}/?insecure=1&sni=${H2_SNI}#${H2_ALIASES}"

  cat > "${CLIENT_FILE}" <<EOF
=========== Hysteria2 配置 ===========
代理模式：Hysteria2
地址：${ip}
端口：${port}
密码：${pass}
SNI：${H2_SNI}
传输协议：tls
跳过证书验证：true
=========================================
链接：
hy2://${link}
EOF
}

restart_service() {
  systemctl daemon-reload || true
  systemctl enable "${SERVICE}" || true
  systemctl restart "${SERVICE}"
  systemctl status --no-pager "${SERVICE}" | sed -n '1,6p' || true
}

require_installed() {
  if ! is_installed; then
    echo -e "${ERROR} 未检测到安装，请先执行安装。"
    return 1
  fi
  return 0
}

install_hy2() {
  local force="${1:-}"
  if is_installed && [[ "${force}" != "force" ]]; then
    read -rp "检测到已安装，是否覆盖安装并重置端口/密码？(y/N): " ans
    if [[ ! "${ans:-N}" =~ ^[yY]$ ]]; then
      echo "已取消。"
      return
    fi
  fi
  timedatectl set-timezone "${TZ_DEFAULT}" || true
  os_install
  echo "开始安装 Hysteria2..."
  bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh)
  ensure_cert

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)
  write_config "${port}" "${pass}"
  restart_service
  client_export

  clear
  echo -e "${OK} 安装完成，以下为客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}


update_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装"
    return
  fi
  os_install
  echo "更新 Hysteria2 到最新版..."
  bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh)
  restart_service
  client_export
  echo -e "${OK} 更新完成。"
}

view_hy2() {
  if ! require_installed; then return; fi
  client_export
  echo
  cat "${CLIENT_FILE}"
}

set_port() {
  if ! require_installed; then return; fi
  local new_port
  new_port=$(read_port_interactive)
  sed -i -E "s/^listen:\s*:.*/listen: :${new_port}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 端口已更新为：${new_port}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

set_password() {
  if ! require_installed; then return; fi
  local new_pass
  read -p "回车随机生成密码：" new_pass || true
  if [[ -z "${new_pass:-}" ]]; then
    new_pass=$(gen_password)
  fi
  sed -i -E "s/^([[:space:]]*)password:\s*.*/\1password: ${new_pass}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 密码已更新为：${new_pass}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

uninstall_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装"
    return
  fi
  read -p "确认卸载？(y/N): " ans
  if [[ "${ans:-N}" != [yY] ]]; then
    echo "已取消。"
    return
  fi
  systemctl stop "${SERVICE}" || true
  systemctl disable "${SERVICE}" || true
  rm -f /usr/local/bin/hysteria /usr/bin/hysteria || true
  rm -f /etc/systemd/system/${SERVICE} || true
  systemctl daemon-reload || true
  rm -rf "${CONF_DIR}" || true
  echo -e "${OK} 卸载完成。"
}

pause() { read -rp "按回车返回菜单..." _; }

quit() { exit 0; }

hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

draw_header() {
  hr
  echo -e " Hysteria2 一键管理"
  echo -e " https://github.com/xxf185/hysteria"
  echo -e " 当前脚本版本: ${Magenta}${SHELL_VERSION}${Font}"
  echo -e " 安装状态：$(status_text)"
  hr
}

menu() {
  while true; do
    clear
    draw_header
    if is_installed; then
      echo -e "${Cyan}1. 重新安装 ${Font}"
      echo -e "${Cyan}2. 更新core ${Font}"
      echo -e "${Cyan}3. 查看当前配置 ${Font}"
      echo -e "${Cyan}4. 更改端口 ${Font}"
      echo -e "${Cyan}5. 更改密码 ${Font}"
      echo -e "${Cyan}6. 卸载 ${Font}"
      echo -e "${Cyan}0. 退出 ${Font}"
      hr
      read -p "选项 [0-6]: " choice
      case "${choice}" in
        1) install_hy2 "force"; pause ;;
        2) update_hy2; pause ;;
        3) view_hy2; quit ;;
        4) set_port; pause ;;
        5) set_password; pause ;;
        6) uninstall_hy2; pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
      esac
    else
      echo -e "${Cyan}1. 安装${Font}"
      echo -e "${Cyan}0. 退出${Font}"
      hr
      read -p "选项 [0-1]: " choice
      case "${choice}" in
        1) install_hy2; pause ;;
        0) exit 0 ;;
        *) echo "未安装"; pause ;;
      esac
    fi
  done
}

# -------- 主流程 --------
ensure_root
menu

BlackBG="\033[40m"
RedBG="\033[41m"
GreenBG="\033[42m"
YellowBG="\033[43m"
BlueBG="\033[44m"
MagentaBG="\033[45m"
CyanBG="\033[46m"
WhiteBG="\033[47m"

Bold="\033[1m"
Dim="\033[2m"
Italic="\033[3m"
Underline="\033[4m"
Blink="\033[5m"
Reverse="\033[7m"
Hidden="\033[8m"
Strike="\033[9m"

OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

center() {
  local s="$1"
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)

  local noansi
  noansi=$(printf '%b' "$s" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g')

  local width
  width=$(LC_ALL=C.UTF-8 awk -v str="$noansi" '
    BEGIN{
      n = split(str, a, "")
      w = 0
      for(i=1;i<=n;i++){
        c = a[i]
        if (c ~ /[ -~]/) w += 1
        else             w += 2
      }
      print w
    }')

  local pad=$(( (cols - width) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%b\n" "$pad" "" "$s"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl gawk openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl gawk openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl gawk openssl
  else
    echo "未识别的包管理器，请手动安装 curl、gawk、openssl 后重试"
    exit 1
  fi
}

# -------- 安装状态检测 --------
service_installed() { systemctl status "${SERVICE}" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "${SERVICE}"; }

is_installed() {
  # 满足：存在二进制 或 服务可用，并且存在配置文件，认为已安装
  if { has_cmd hysteria || service_installed; } && [[ -f "${CONF_FILE}" ]]; then
    return 0
  fi
  return 1
}

status_text() {
  if is_installed; then
    if service_active; then
      echo -e "${BGreen}已安装（运行中）${Font}"
    else
      echo -e "${BYellow}已安装（已停止）${Font}"
    fi
  else
    echo -e "${BRed}未安装${Font}"
  fi
}

get_ip() {
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip4}" ]]; then
    echo "${ip4}"
    return
  fi
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip6}" ]]; then
    echo "${ip6}"
    return
  fi
  curl -s https://api.ipify.org || true
}

random_port() { shuf -i 2000-65000 -n 1; }

# 确保端口是数字并且在合法范围内
valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 检查端口是否被占用
is_port_free() {
  local port="$1"
  ss -tuln | grep ":$port " >/dev/null 2>&1
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi

    # 验证端口是否合法
    if ! valid_port "$input"; then
      echo "端口不合法：$input，请输入一个有效的端口（1-65535）。"
      continue
    fi

    # 检查端口是否被占用
    if is_port_free "$input"; then
      echo "端口 $input 已被占用，请选择另一个端口。"
      continue
    fi

    # 如果端口合法且未被占用，退出循环
    echo "$input"
    break
  done
}

gen_password() { cat /proc/sys/kernel/random/uuid; }

ensure_cert() {
  mkdir -p "${CONF_DIR}"
  if [[ ! -f "${CONF_DIR}/server.key" || ! -f "${CONF_DIR}/server.crt" ]]; then
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "${CONF_DIR}/server.key" \
      -out "${CONF_DIR}/server.crt" -subj "/CN=${H2_SNI}" -days 36500
    chown hysteria:hysteria "${CONF_DIR}/server.key" "${CONF_DIR}/server.crt" || true
  fi
}

write_config() {
  # 参数：端口 密码
  local port="$1" pass="$2"
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" <<EOF
listen: :${port}
tls:
  cert: ${CONF_DIR}/server.crt
  key: ${CONF_DIR}/server.key

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: https://${H2_SNI}
    rewriteHost: true
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
}

client_export() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    echo "未找到 ${CONF_FILE}"
    return 1
  fi
  local port pass ip link
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONF_FILE}")
  if [[ -z "${port}" ]]; then
    port=$(awk '/^[[:space:]]*listen:/ { if (match($0, /:([0-9]+)[[:space:]]*$/, a)) print a[1] }' "${CONF_FILE}")
  fi
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONF_FILE}")
  ip=$(get_ip)
  link="${pass}@${ip}:${port}/?insecure=1&sni=${H2_SNI}#${H2_ALIASES}"

  cat > "${CLIENT_FILE}" <<EOF
=========== Hysteria2 配置 ===========
代理模式：Hysteria2
地址：${ip}
端口：${port}
密码：${pass}
SNI：${H2_SNI}
传输协议：tls
跳过证书验证：true
=========================================
链接：
hy2://${link}
EOF
}

restart_service() {
  systemctl daemon-reload || true
  systemctl enable "${SERVICE}" || true
  systemctl restart "${SERVICE}"
  systemctl status --no-pager "${SERVICE}" | sed -n '1,6p' || true
}

require_installed() {
  if ! is_installed; then
    echo -e "${ERROR} 未检测到安装，请先执行安装。"
    return 1
  fi
  return 0
}

install_hy2() {
  local force="${1:-}"
  if is_installed && [[ "${force}" != "force" ]]; then
    read -rp "检测到已安装，是否覆盖安装并重置端口/密码？(y/N): " ans
    if [[ ! "${ans:-N}" =~ ^[yY]$ ]]; then
      echo "已取消。"
      return
    fi
  fi
  timedatectl set-timezone "${TZ_DEFAULT}" || true
  os_install
  echo "开始安装 Hysteria2..."
  bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh)
  ensure_cert

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)
  write_config "${port}" "${pass}"
  restart_service
  client_export

  clear
  echo -e "${OK} 安装完成，以下为客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}


update_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装"
    return
  fi
  os_install
  echo "更新 Hysteria2 到最新版..."
  bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh)
  restart_service
  client_export
  echo -e "${OK} 更新完成。"
}

view_hy2() {
  if ! require_installed; then return; fi
  client_export
  echo
  cat "${CLIENT_FILE}"
}

set_port() {
  if ! require_installed; then return; fi
  local new_port
  new_port=$(read_port_interactive)
  sed -i -E "s/^listen:\s*:.*/listen: :${new_port}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 端口已更新为：${new_port}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

set_password() {
  if ! require_installed; then return; fi
  local new_pass
  read -p "回车随机生成密码：" new_pass || true
  if [[ -z "${new_pass:-}" ]]; then
    new_pass=$(gen_password)
  fi
  sed -i -E "s/^([[:space:]]*)password:\s*.*/\1password: ${new_pass}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 密码已更新为：${new_pass}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

uninstall_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装"
    return
  fi
  read -p "确认卸载？(y/N): " ans
  if [[ "${ans:-N}" != [yY] ]]; then
    echo "已取消。"
    return
  fi
  systemctl stop "${SERVICE}" || true
  systemctl disable "${SERVICE}" || true
  rm -f /usr/local/bin/hysteria /usr/bin/hysteria || true
  rm -f /etc/systemd/system/${SERVICE} || true
  systemctl daemon-reload || true
  rm -rf "${CONF_DIR}" || true
  echo -e "${OK} 卸载完成。"
}

pause() { read -rp "按回车返回菜单..." _; }

quit() { exit 0; }

hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

draw_header() {
  hr
  echo -e " Hysteria2 一键管理"
  echo -e " https://github.com/xxf185/hysteria"
  echo -e " 当前脚本版本: ${Magenta}${SHELL_VERSION}${Font}"
  echo -e " 安装状态：$(status_text)"
  hr
}

menu() {
  while true; do
    clear
    draw_header
    if is_installed; then
      echo -e "${Cyan}1. 重新安装 ${Font}"
      echo -e "${Cyan}2. 更新core ${Font}"
      echo -e "${Cyan}3. 查看当前配置 ${Font}"
      echo -e "${Cyan}4. 更改端口 ${Font}"
      echo -e "${Cyan}5. 更改密码 ${Font}"
      echo -e "${Cyan}6. 卸载 ${Font}"
      echo -e "${Cyan}0. 退出 ${Font}"
      hr
      read -p "选项 [0-6]: " choice
      case "${choice}" in
        1) install_hy2 "force"; pause ;;
        2) update_hy2; pause ;;
        3) view_hy2; quit ;;
        4) set_port; pause ;;
        5) set_password; pause ;;
        6) uninstall_hy2; pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
      esac
    else
      echo -e "${Cyan}1. 安装${Font}"
      echo -e "${Cyan}0. 退出${Font}"
      hr
      read -p "选项 [0-1]: " choice
      case "${choice}" in
        1) install_hy2; pause ;;
        0) exit 0 ;;
        *) echo "未安装"; pause ;;
      esac
    fi
  done
}

# -------- 主流程 --------
ensure_root
menu
}

print_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

print_header() {
    echo -e "${CYAN}$1${NC}"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 用户身份运行"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_error "无法检测操作系统"
        exit 1
    fi
    
    print_info "检测到操作系统: $OS $VERSION"
}

# 更新系统包
update_system() {
    print_info "正在更新系统..."
    
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update
        apt-get upgrade -y
        apt-get install -y wget curl git openssl ca-certificates jq
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
        yum update -y
        yum install -y wget curl git openssl ca-certificates jq
    fi
    
    print_info "系统更新完成"
}

# 安装 Hysteria2 二进制文件
install_hysteria2_binary() {
    print_info "正在下载 Hysteria2 预编译二进制文件..."
    
    mkdir -p $HYSTERIA_BIN_DIR
    
    # 获取最新版本
    HYSTERIA_VERSION=$(curl -s "https://api.github.com/repos/xxf185/hysteria/releases/latest" | grep "tag_name" | cut -d'"' -f4 | sed 's/v//')
    print_info "Hysteria2 最新版本: $HYSTERIA_VERSION"
    
    cd /tmp
    
    # 判断系统架构
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    else
        print_error "不支持的系统架构: $ARCH"
        return 1
    fi
    
    # 下载二进制文件
    HYSTERIA_FILE="hysteria-linux-${ARCH}"
    
    rm -f $HYSTERIA_FILE
    
    print_info "下载 $HYSTERIA_FILE..."
    if ! wget -q "https://github.com/xxf185/hysteria/releases/latest/download/${HYSTERIA_FILE}"; then
        print_error "下载失败，请检查网络连接"
        return 1
    fi
    
    chmod +x $HYSTERIA_FILE
    cp $HYSTERIA_FILE $HYSTERIA_BIN_DIR/hysteria
    rm $HYSTERIA_FILE
    
    # 保存版本信息
    echo "$HYSTERIA_VERSION" > $HYSTERIA_CONFIG_DIR/version.txt
    
    print_success "Hysteria2 二进制文件安装完成"
}

# 生成自签名证书
generate_cert() {
    print_info "生成自签名 TLS 证书..."
    
    mkdir -p $HYSTERIA_CONFIG_DIR
    
    DOMAIN=${1:-"hysteria2.local"}
    
    # 如果证书已存在，询问是否覆盖
    if [ -f "$HYSTERIA_CONFIG_DIR/cert.crt" ] && [ -f "$HYSTERIA_CONFIG_DIR/private.key" ]; then
        read -p "证书已存在，是否覆盖? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "使用现有证书"
            return
        fi
    fi
    
    # 生成私钥
    openssl genrsa -out $HYSTERIA_CONFIG_DIR/private.key 2048
    
    # 生成证书
    openssl req -new -x509 -key $HYSTERIA_CONFIG_DIR/private.key -out $HYSTERIA_CONFIG_DIR/cert.crt -days 365 \
        -subj "/C=CN/ST=State/L=City/O=Organization/CN=$DOMAIN"
    
    chmod 600 $HYSTERIA_CONFIG_DIR/private.key
    chmod 644 $HYSTERIA_CONFIG_DIR/cert.crt
    
    print_success "证书生成完成"
}

# 生成随机密码
generate_password() {
    openssl rand -base64 32
}

# 提示用户输入端口
prompt_port() {
    local default_port=$1
    read -p "请输入监听端口 (默认 $default_port): " input_port
    
    if [ -z "$input_port" ]; then
        echo $default_port
    else
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            echo $input_port
        else
            print_error "无效的端口号，使用默认端口 $default_port"
            echo $default_port
        fi
    fi
}

# 创建 Hysteria2 配置文件
create_config() {
    print_info "创建 Hysteria2 配置文件..."
    
    mkdir -p $HYSTERIA_CONFIG_DIR
    mkdir -p $HYSTERIA_DATA_DIR
    
    # 如果配置文件已存在，询问用户
    if [ -f "$CONFIG_FILE" ]; then
        print_warn "配置文件已存在: $CONFIG_FILE"
        read -p "是否覆盖现有配置? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "保留现有配置"
            return
        fi
    fi
    
    # 生成用户密码
    USER_PASSWORD=$(generate_password)
    
    print_info "生成用户密码: $USER_PASSWORD"
    
    # 提示输入端口
    print_header "========== 端口配置 =========="
    LISTEN_PORT=$(prompt_port 443)
    echo ""
    
    # 创建配置文件
    cat > $CONFIG_FILE << EOF
# Hysteria2 服务器配置文件

# 监听地址和端口
listen: :$LISTEN_PORT

# TLS 证书配置
tls:
  cert: $HYSTERIA_CONFIG_DIR/cert.crt
  key: $HYSTERIA_CONFIG_DIR/private.key

# 认证密码
auth:
  type: password
  password: $USER_PASSWORD

# QUIC 配置
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxHandshakeTimeout: 10s
  disablePathMTUDiscovery: false

# 日志级别
logLevel: warn

# 掩码配置（可选）
masquerade:
  type: file
  file: /var/www/html/index.html
EOF
    
    chmod 600 $CONFIG_FILE
    
    print_success "配置文件创建完成: $CONFIG_FILE"
    
    # 显示用户信息
    echo ""
    print_header "========== Hysteria2 用户信息 =========="
    echo "密码: $USER_PASSWORD"
    echo "端口: $LISTEN_PORT"
    print_header "========================================"
    echo ""
    
    # 保存用户信息到文件
    cat > $HYSTERIA_CONFIG_DIR/users.txt << INFO
密码: $USER_PASSWORD
端口: $LISTEN_PORT
INFO
    
    print_info "用户信息已保存到 $HYSTERIA_CONFIG_DIR/users.txt"
}

# 创建 Systemd 服务文件
create_systemd_service() {
    print_info "创建 Systemd 服务..."
    
    cat > /etc/systemd/system/hysteria2.service << 'SERVICE_CONFIG'
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hysteria2
ExecStart=/opt/hysteria2/hysteria -c /etc/hysteria2/config.yaml server
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
SERVICE_CONFIG
    
    systemctl daemon-reload
    print_success "Systemd 服务创建完成"
}

# 配置防火墙
setup_firewall() {
    print_info "配置防火墙..."
    
    # 从配置文件读取端口
    PORT=$(grep -oP "listen:\s*:\K\d+" "$CONFIG_FILE" || echo "443")
    
    if command -v ufw &> /dev/null; then
        ufw allow $PORT/udp
        ufw allow $PORT/tcp
        print_info "UFW 防火墙规则添加完成 (端口: $PORT)"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/udp
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --reload
        print_info "Firewalld 防火墙规则添加完成 (端口: $PORT)"
    else
        print_warn "未检测到防火墙管理工具，请手动配置防火墙"
    fi
}

# 启动服务
start_service() {
    print_info "启动 Hysteria2 服务..."
    
    systemctl enable hysteria2
    systemctl start hysteria2
    
    sleep 2
    
    if systemctl is-active --quiet hysteria2; then
        print_success "Hysteria2 服务启动成功"
    else
        print_error "Hysteria2 服务启动失败"
        systemctl status hysteria2
        journalctl -u hysteria2 -n 50
        exit 1
    fi
}

# 显示连接信息
show_connection_info() {
    print_header "========== Hysteria2 连接信息 =========="
    
    # 获取服务器 IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    # 从配置文件读取端口和密码
    PORT=$(grep -oP "listen:\s*:\K\d+" "$CONFIG_FILE" || echo "443")
    PASSWORD=$(grep -oP "password:\s*\K.*" "$CONFIG_FILE" | head -1)
    
    echo ""
    echo "服务器地址: $SERVER_IP"
    echo "端口: $PORT"
    echo "密码: $PASSWORD"
    echo ""
    echo "配置文件: $CONFIG_FILE"
    echo "日志查看: journalctl -u hysteria2 -f"
    echo ""
    echo "客户端连接示例:"
    echo "hysteria2://[PASSWORD]@[SERVER_IP]:$PORT"
    echo ""
    print_header "========================================"
}

# 创建完整的管理脚本
create_management_scripts() {
    print_info "创建管理脚本..."
    
    # 创建端口修改脚本
    cat > /usr/local/bin/hysteria2-change-port << 'PORT_SCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="/etc/hysteria2/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} 配置文件不存在"
    exit 1
fi

# 显示当前端口
CURRENT_PORT=$(grep -oP "listen:\s*:\K\d+" "$CONFIG_FILE")
echo -e "${YELLOW}当前端口: $CURRENT_PORT${NC}"

read -p "请输入新的端口号: " NEW_PORT

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}[ERROR]${NC} 无效的端口号"
    exit 1
fi

if [ "$NEW_PORT" -eq "$CURRENT_PORT" ]; then
    echo -e "${BLUE}[INFO]${NC} 新端口与当前端口相同"
    exit 0
fi

if netstat -tuln 2>/dev/null | grep -q ":$NEW_PORT " || ss -tuln 2>/dev/null | grep -q ":$NEW_PORT "; then
    echo -e "${RED}[ERROR]${NC} 端口 $NEW_PORT 已被占用"
    exit 1
fi

echo -e "${GREEN}[INFO]${NC} 正在修改端口..."

sed -i "s/listen: :$CURRENT_PORT/listen: :$NEW_PORT/" "$CONFIG_FILE"

if command -v ufw &> /dev/null; then
    ufw delete allow $CURRENT_PORT/udp 2>/dev/null || true
    ufw delete allow $CURRENT_PORT/tcp 2>/dev/null || true
    ufw allow $NEW_PORT/udp
    ufw allow $NEW_PORT/tcp
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --remove-port=$CURRENT_PORT/udp 2>/dev/null || true
    firewall-cmd --permanent --remove-port=$CURRENT_PORT/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=$NEW_PORT/udp
    firewall-cmd --permanent --add-port=$NEW_PORT/tcp
    firewall-cmd --reload
fi

systemctl restart hysteria2

if systemctl is-active --quiet hysteria2; then
    echo -e "${BLUE}[SUCCESS]${NC} 端口已改为: $NEW_PORT"
else
    echo -e "${RED}[ERROR]${NC} 服务启动失败"
fi
PORT_SCRIPT

    chmod +x /usr/local/bin/hysteria2-change-port
    
    # 创建密码修改脚本
    cat > /usr/local/bin/hysteria2-change-password << 'PASSWORD_SCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="/etc/hysteria2/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} 配置文件不存在"
    exit 1
fi

read -p "请输入新密码 (默认随机生成): " NEW_PASSWORD

if [ -z "$NEW_PASSWORD" ]; then
    NEW_PASSWORD=$(openssl rand -base64 32)
    echo -e "${GREEN}[INFO]${NC} 生成随机密码: $NEW_PASSWORD"
fi

# 获取当前密码
CURRENT_PASSWORD=$(grep -oP "password:\s*\K.*" "$CONFIG_FILE")

sed -i "s/password: $CURRENT_PASSWORD/password: $NEW_PASSWORD/" "$CONFIG_FILE"

systemctl restart hysteria2

if systemctl is-active --quiet hysteria2; then
    echo -e "${BLUE}[SUCCESS]${NC} 密码已更改: $NEW_PASSWORD"
else
    echo -e "${RED}[ERROR]${NC} 服务启动失败"
fi
PASSWORD_SCRIPT

    chmod +x /usr/local/bin/hysteria2-change-password
    
    # 创建升级脚本
    cat > /usr/local/bin/hysteria2-upgrade << 'UPGRADE_SCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HYSTERIA_BIN_DIR="/opt/hysteria2"
HYSTERIA_CONFIG_DIR="/etc/hysteria2"

echo -e "${BLUE}[INFO]${NC} 检查 Hysteria2 更新..."

# 获取最新版本
LATEST_VERSION=$(curl -s "https://api.github.com/repos/xxf185/hysteria/releases/latest" | grep "tag_name" | cut -d'"' -f4 | sed 's/v//')
CURRENT_VERSION=$(cat $HYSTERIA_CONFIG_DIR/version.txt 2>/dev/null || echo "unknown")

echo -e "${BLUE}[INFO]${NC} 当前版本: $CURRENT_VERSION"
echo -e "${BLUE}[INFO]${NC} 最新版本: $LATEST_VERSION"

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo -e "${GREEN}[SUCCESS]${NC} 已是最新版本"
    exit 0
fi

read -p "是否升级? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}[WARN]${NC} 已取消升级"
    exit 0
fi

echo -e "${BLUE}[INFO]${NC} 停止服务..."
systemctl stop hysteria2

cd /tmp

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    ARCH="arm64"
fi

HYSTERIA_FILE="hysteria-linux-${ARCH}"

echo -e "${BLUE}[INFO]${NC} 下载新版本..."
if ! wget -q "https://github.com/xxf185/hysteria/releases/latest/download/${HYSTERIA_FILE}"; then
    echo -e "${RED}[ERROR]${NC} 下载失败"
    systemctl start hysteria2
    exit 1
fi

chmod +x $HYSTERIA_FILE
cp $HYSTERIA_FILE $HYSTERIA_BIN_DIR/hysteria

echo "$LATEST_VERSION" > $HYSTERIA_CONFIG_DIR/version.txt

rm $HYSTERIA_FILE

echo -e "${BLUE}[INFO]${NC} 启动服务..."
systemctl start hysteria2

sleep 2

if systemctl is-active --quiet hysteria2; then
    echo -e "${GREEN}[SUCCESS]${NC} 升级完成！新版本: $LATEST_VERSION"
else
    echo -e "${RED}[ERROR]${NC} 服务启动失败"
fi
UPGRADE_SCRIPT

    chmod +x /usr/local/bin/hysteria2-upgrade
    
    # 创建卸载脚本
    cat > /usr/local/bin/hysteria2-uninstall << 'UNINSTALL_SCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}========== Hysteria2 卸载脚本 ==========${NC}"
echo ""
echo -e "${RED}警告：此操作将卸载 Hysteria2 及其所有配置${NC}"
echo ""

read -p "您确定要卸载 Hysteria2 吗? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${BLUE}[INFO]${NC} 已取消卸载"
    exit 0
fi

echo -e "${BLUE}[INFO]${NC} 停止服务..."
systemctl stop hysteria2 2>/dev/null || true

echo -e "${BLUE}[INFO]${NC} 禁用服务..."
systemctl disable hysteria2 2>/dev/null || true

echo -e "${BLUE}[INFO]${NC} 删除服务文件..."
rm -f /etc/systemd/system/hysteria2.service
systemctl daemon-reload

echo -e "${BLUE}[INFO]${NC} 删除二进制文件..."
rm -rf /opt/hysteria2

echo -e "${BLUE}[INFO]${NC} 删除配置文件..."
read -p "是否删除配置文件? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf /etc/hysteria2
fi

echo -e "${BLUE}[INFO]${NC} 删除管理脚本..."
rm -f /usr/local/bin/hysteria2-*

echo -e "${BLUE}[INFO]${NC} 删除日志..."
rm -f /var/log/hysteria2.log

echo -e "${GREEN}[SUCCESS]${NC} Hysteria2 已卸载"
UNINSTALL_SCRIPT

    chmod +x /usr/local/bin/hysteria2-uninstall
    
    # 创建管理菜单脚本
    cat > /usr/local/bin/hysteria2-manage << 'MANAGE_SCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════╗"
    echo "║   Hysteria2 服务管理菜单           ║"
    echo "╚════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} 查看服务状态"
    echo -e "${GREEN}2.${NC} 启动服务"
    echo -e "${GREEN}3.${NC} 停止服务"
    echo -e "${GREEN}4.${NC} 重启服务"
    echo -e "${GREEN}5.${NC} 查看实时日志"
    echo -e "${GREEN}6.${NC} 修改监听端口"
    echo -e "${GREEN}7.${NC} 修改密码"
    echo -e "${GREEN}8.${NC} 查看连接信息"
    echo -e "${GREEN}9.${NC} 查看配置文件"
    echo -e "${GREEN}10.${NC} 升级 Hysteria2 核心"
    echo -e "${GREEN}11.${NC} 卸载 Hysteria2"
    echo -e "${GREEN}0.${NC} 退出"
    echo ""
}

while true; do
    show_menu
    read -p "请选择操作 (0-11): " choice
    
    case $choice in
        1)
            systemctl status hysteria2
            read -p "按 Enter 继续..."
            ;;
        2)
            systemctl start hysteria2
            echo -e "${BLUE}[SUCCESS]${NC} 服务已启动"
            read -p "按 Enter 继续..."
            ;;
        3)
            systemctl stop hysteria2
            echo -e "${BLUE}[SUCCESS]${NC} 服务已停止"
            read -p "按 Enter 继续..."
            ;;
        4)
            systemctl restart hysteria2
            echo -e "${BLUE}[SUCCESS]${NC} 服务已重启"
            read -p "按 Enter 继续..."
            ;;
        5)
            journalctl -u hysteria2 -f
            ;;
        6)
            hysteria2-change-port
            read -p "按 Enter 继续..."
            ;;
        7)
            hysteria2-change-password
            read -p "按 Enter 继续..."
            ;;
        8)
            CONFIG_FILE="/etc/hysteria2/config.yaml"
            SERVER_IP=$(hostname -I | awk '{print $1}')
            PORT=$(grep -oP "listen:\s*:\K\d+" "$CONFIG_FILE")
            PASSWORD=$(grep -oP "password:\s*\K.*" "$CONFIG_FILE" | head -1)
            echo ""
            echo -e "${CYAN}========== Hysteria2 连接信息 ==========${NC}"
            echo "服务器: $SERVER_IP"
            echo "端口: $PORT"
            echo "密码: $PASSWORD"
            echo "连接链接: hysteria2://$PASSWORD@$SERVER_IP:$PORT"
            echo -e "${CYAN}========================================${NC}"
            read -p "按 Enter 继续..."
            ;;
        9)
            cat /etc/hysteria2/config.yaml
            read -p "按 Enter 继续..."
            ;;
        10)
            hysteria2-upgrade
            read -p "按 Enter 继续..."
            ;;
        11)
            hysteria2-uninstall
            exit 0
            ;;
        0)
            echo -e "${YELLOW}感谢使用，再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择，请重试${NC}"
            read -p "按 Enter 继续..."
            ;;
    esac
done
MANAGE_SCRIPT

    chmod +x /usr/local/bin/hysteria2-manage
    
    print_success "管理脚本创建完成"
}

# 创建快速查看脚本
create_quick_info_script() {
    print_info "创建快速查看脚本..."
    
    cat > /usr/local/bin/hysteria2-info << 'INFO_SCRIPT'
#!/bin/bash

BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/hysteria2/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${BLUE}[ERROR]${NC} 配置文件不存在"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
PORT=$(grep -oP "listen:\s*:\K\d+" "$CONFIG_FILE")
PASSWORD=$(grep -oP "password:\s*\K.*" "$CONFIG_FILE" | head -1)
VERSION=$(cat /etc/hysteria2/version.txt 2>/dev/null || echo "unknown")

echo ""
echo -e "${CYAN}========== Hysteria2 信息 ==========${NC}"
echo "版本: $VERSION"
echo "服务器: $SERVER_IP"
echo "端口: $PORT"
echo "密码: $PASSWORD"
echo ""
echo -e "${CYAN}连接链接:${NC}"
echo "hysteria2://$PASSWORD@$SERVER_IP:$PORT"
echo ""
echo -e "${CYAN}=====================================${NC}"
INFO_SCRIPT

    chmod +x /usr/local/bin/hysteria2-info
    print_success "快速查看脚本创建完成"
}

# 主函数
main() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════╗"
    echo "║  Hysteria2 完整功能安装脚本        ║"
    echo "║  支持：修改端口、密码、升级、卸载 ║"
    echo "╚════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    check_root
    detect_os
    update_system
    install_hysteria2_binary
    generate_cert
    create_config
    create_systemd_service
    setup_firewall
    start_service
    create_management_scripts
    create_quick_info_script
    show_connection_info
    
    print_success "Hysteria2 安装和配置完成！"
    echo ""
    print_header "========== 可用的管理命令 =========="
    echo "hysteria2-manage            # 进入交互式管理菜单（推荐）"
    echo "hysteria2-info              # 快速查看配置信息"
    echo "hysteria2-change-port       # 修改监听端口"
    echo "hysteria2-change-password   # 修改密码"
    echo "hysteria2-upgrade           # 升级 Hysteria2 核心"
    echo "hysteria2-uninstall         # 卸载 Hysteria2"
    echo ""
    echo "systemctl start hysteria2     # 启动服务"
    echo "systemctl stop hysteria2      # 停止服务"
    echo "systemctl restart hysteria2   # 重启服务"
    echo "systemctl status hysteria2    # 查看状态"
    echo "journalctl -u hysteria2 -f    # 查看实时日志"
    print_header "===================================="
    echo ""
    echo -e "${GREEN}下一步：${NC}"
    echo "运行 ${CYAN}hysteria2-manage${NC} 进入管理菜单"
    echo "或运行 ${CYAN}hysteria2-info${NC} 查看连接信息"
    echo ""
}

# 运行主函数
main "$@"
BlackBG="\033[40m"
RedBG="\033[41m"
GreenBG="\033[42m"
YellowBG="\033[43m"
BlueBG="\033[44m"
MagentaBG="\033[45m"
CyanBG="\033[46m"
WhiteBG="\033[47m"

Bold="\033[1m"
Dim="\033[2m"
Italic="\033[3m"
Underline="\033[4m"
Blink="\033[5m"
Reverse="\033[7m"
Hidden="\033[8m"
Strike="\033[9m"

OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

center() {
  local s="$1"
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)

  local noansi
  noansi=$(printf '%b' "$s" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g')

  local width
  width=$(LC_ALL=C.UTF-8 awk -v str="$noansi" '
    BEGIN{
      n = split(str, a, "")
      w = 0
      for(i=1;i<=n;i++){
        c = a[i]
        if (c ~ /[ -~]/) w += 1
        else             w += 2
      }
      print w
    }')

  local pad=$(( (cols - width) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%b\n" "$pad" "" "$s"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl gawk openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl gawk openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl gawk openssl
  else
    echo "未识别的包管理器，请手动安装 curl、gawk、openssl 后重试"
    exit 1
  fi
}

# -------- 安装状态检测 --------
service_installed() { systemctl status "${SERVICE}" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "${SERVICE}"; }

is_installed() {
  # 满足：存在二进制 或 服务可用，并且存在配置文件，认为已安装
  if { has_cmd hysteria || service_installed; } && [[ -f "${CONF_FILE}" ]]; then
    return 0
  fi
  return 1
}

status_text() {
  if is_installed; then
    if service_active; then
      echo -e "${BGreen}已安装（运行中）${Font}"
    else
      echo -e "${BYellow}已安装（已停止）${Font}"
    fi
  else
    echo -e "${BRed}未安装${Font}"
  fi
}

get_ip() {
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip4}" ]]; then
    echo "${ip4}"
    return
  fi
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip6}" ]]; then
    echo "${ip6}"
    return
  fi
  curl -s https://api.ipify.org || true
}

random_port() { shuf -i 2000-65000 -n 1; }

# 确保端口是数字并且在合法范围内
valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 检查端口是否被占用
is_port_free() {
  local port="$1"
  ss -tuln | grep ":$port " >/dev/null 2>&1
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi

    # 验证端口是否合法
    if ! valid_port "$input"; then
      echo "端口不合法：$input，请输入一个有效的端口（1-65535）。"
      continue
    fi

    # 检查端口是否被占用
    if is_port_free "$input"; then
      echo "端口 $input 已被占用，请选择另一个端口。"
      continue
    fi

    # 如果端口合法且未被占用，退出循环
    echo "$input"
    break
  done
}

gen_password() { cat /proc/sys/kernel/random/uuid; }

ensure_cert() {
  mkdir -p "${CONF_DIR}"
  if [[ ! -f "${CONF_DIR}/server.key" || ! -f "${CONF_DIR}/server.crt" ]]; then
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "${CONF_DIR}/server.key" \
      -out "${CONF_DIR}/server.crt" -subj "/CN=${H2_SNI}" -days 36500
    chown hysteria:hysteria "${CONF_DIR}/server.key" "${CONF_DIR}/server.crt" || true
  fi
}

write_config() {
  # 参数：端口 密码
  local port="$1" pass="$2"
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" <<EOF
listen: :${port}
tls:
  cert: ${CONF_DIR}/server.crt
  key: ${CONF_DIR}/server.key

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: https://${H2_SNI}
    rewriteHost: true
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
}

client_export() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    echo "未找到 ${CONF_FILE}"
    return 1
  fi
  local port pass ip link
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONF_FILE}")
  if [[ -z "${port}" ]]; then
    port=$(awk '/^[[:space:]]*listen:/ { if (match($0, /:([0-9]+)[[:space:]]*$/, a)) print a[1] }' "${CONF_FILE}")
  fi
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONF_FILE}")
  ip=$(get_ip)
  link="${pass}@${ip}:${port}/?insecure=1&sni=${H2_SNI}#${H2_ALIASES}"

  cat > "${CLIENT_FILE}" <<EOF
=========== Hysteria2 配置 ===========
代理模式：Hysteria2
地址：${ip}
端口：${port}
密码：${pass}
SNI：${H2_SNI}
传输协议：tls
跳过证书验证：true
=========================================
链接：
hy2://${link}
EOF
}

restart_service() {
  systemctl daemon-reload || true
  systemctl enable "${SERVICE}" || true
  systemctl restart "${SERVICE}"
  systemctl status --no-pager "${SERVICE}" | sed -n '1,6p' || true
}

require_installed() {
  if ! is_installed; then
    echo -e "${ERROR} 未检测到安装，请先执行安装。"
    return 1
  fi
  return 0
}

install_hy2() {
  local force="${1:-}"
  if is_installed && [[ "${force}" != "force" ]]; then
    read -rp "检测到已安装，是否覆盖安装并重置端口/密码？(y/N): " ans
    if [[ ! "${ans:-N}" =~ ^[yY]$ ]]; then
      echo "已取消。"
      return
    fi
  fi
  timedatectl set-timezone "${TZ_DEFAULT}" || true
  os_install
  echo "开始安装 Hysteria2..."
  bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh)
  ensure_cert

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)
  write_config "${port}" "${pass}"
  restart_service
  client_export

  clear
  echo -e "${OK} 安装完成，以下为客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}


update_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装"
    return
  fi
  os_install
  echo "更新 Hysteria2 到最新版..."
  bash <(curl -fsSL https://raw.githubusercontent.com/xxf185/hysteria/master/install_server.sh)
  restart_service
  client_export
  echo -e "${OK} 更新完成。"
}

view_hy2() {
  if ! require_installed; then return; fi
  client_export
  echo
  cat "${CLIENT_FILE}"
}

set_port() {
  if ! require_installed; then return; fi
  local new_port
  new_port=$(read_port_interactive)
  sed -i -E "s/^listen:\s*:.*/listen: :${new_port}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 端口已更新为：${new_port}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

set_password() {
  if ! require_installed; then return; fi
  local new_pass
  read -p "回车随机生成密码：" new_pass || true
  if [[ -z "${new_pass:-}" ]]; then
    new_pass=$(gen_password)
  fi
  sed -i -E "s/^([[:space:]]*)password:\s*.*/\1password: ${new_pass}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 密码已更新为：${new_pass}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

uninstall_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装"
    return
  fi
  read -p "确认卸载？(y/N): " ans
  if [[ "${ans:-N}" != [yY] ]]; then
    echo "已取消。"
    return
  fi
  systemctl stop "${SERVICE}" || true
  systemctl disable "${SERVICE}" || true
  rm -f /usr/local/bin/hysteria /usr/bin/hysteria || true
  rm -f /etc/systemd/system/${SERVICE} || true
  systemctl daemon-reload || true
  rm -rf "${CONF_DIR}" || true
  echo -e "${OK} 卸载完成。"
}

pause() { read -rp "按回车返回菜单..." _; }

quit() { exit 0; }

hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

draw_header() {
  hr
  echo -e " Hysteria2 一键管理"
  echo -e " https://github.com/xxf185/hysteria"
  echo -e " 当前脚本版本: ${Magenta}${SHELL_VERSION}${Font}"
  echo -e " 安装状态：$(status_text)"
  hr
}

menu() {
  while true; do
    clear
    draw_header
    if is_installed; then
      echo -e "${Cyan}1. 重新安装 ${Font}"
      echo -e "${Cyan}2. 更新core ${Font}"
      echo -e "${Cyan}3. 查看当前配置 ${Font}"
      echo -e "${Cyan}4. 更改端口 ${Font}"
      echo -e "${Cyan}5. 更改密码 ${Font}"
      echo -e "${Cyan}6. 卸载 ${Font}"
      echo -e "${Cyan}0. 退出 ${Font}"
      hr
      read -p "选项 [0-6]: " choice
      case "${choice}" in
        1) install_hy2 "force"; pause ;;
        2) update_hy2; pause ;;
        3) view_hy2; quit ;;
        4) set_port; pause ;;
        5) set_password; pause ;;
        6) uninstall_hy2; pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
      esac
    else
      echo -e "${Cyan}1. 安装${Font}"
      echo -e "${Cyan}0. 退出${Font}"
      hr
      read -p "选项 [0-1]: " choice
      case "${choice}" in
        1) install_hy2; pause ;;
        0) exit 0 ;;
        *) echo "未安装"; pause ;;
      esac
    fi
  done
}

# -------- 主流程 --------
ensure_root
menu
