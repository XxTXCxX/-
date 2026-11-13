#!/bin/sh
# =====================================================================
#  xray-alpine-oneclick.sh   v1.1
#  Alpine Linux (OpenRC + BusyBox ash) Xray 一键部署脚本
#
#  支持创建两种入站（可同时存在，互不影响）：
#    1) Trojan + TCP   + REALITY
#    2) VLESS  + XHTTP + REALITY
#
#  默认端口（菜单里可改）：Trojan 53999、VLESS 53666
#  SNI 可填 "域名" 或 "域名:端口"（端口即 REALITY 的 dest 端口）
#  默认 SNI：Trojan www.microsoft.com:443、VLESS www.apple.com:443
#
#  用法：
#    chmod +x xray-alpine-oneclick.sh
#    ./xray-alpine-oneclick.sh          # 菜单模式
#    ./xray-alpine-oneclick.sh auto     # 全自动：装内核 + 两个节点(53999/53666)
# =====================================================================

XRAY_BIN="/usr/local/bin/xray"
ASSET_DIR="/usr/local/share/xray"
CONF_DIR="/usr/local/etc/xray"
CONF="${CONF_DIR}/config.json"
LOG_DIR="/var/log/xray"
STATE="${CONF_DIR}/oneclick.conf"
INIT="/etc/init.d/xray"

# 默认端口（auto 模式使用；菜单模式下同样作为输入框默认值）
AUTO_T_PORT=53999
AUTO_V_PORT=53666
DEFAULT_SNI_T="www.microsoft.com"
DEFAULT_SNI_V="www.apple.com"

# 下载源（GitHub 直连 + 常用加速镜像，按顺序尝试）
MIRRORS="https://github.com/XTLS/Xray-core/releases/latest/download \
https://ghfast.top/https://github.com/XTLS/Xray-core/releases/latest/download \
https://gh-proxy.com/https://github.com/XTLS/Xray-core/releases/latest/download \
https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/latest/download"

C_R="\033[31m"; C_G="\033[32m"; C_Y="\033[33m"; C_B="\033[36m"; C_0="\033[0m"

info() { printf "${C_B}[*]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[+]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*"; }
err()  { printf "${C_R}[x]${C_0} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
line() { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------------
# 交互与工具函数
# ---------------------------------------------------------------------
# prompt "提示" "默认值"  -> 结果输出到 stdout（提示语走 stderr，便于被捕获）
prompt() {
    _p=$1; _d=${2-}
    if [ -n "$_d" ]; then printf "%s [%s]: " "$_p" "$_d" >&2
    else printf "%s: " "$_p" >&2; fi
    _r=""
    IFS= read -r _r || _r=""
    [ -z "$_r" ] && _r=$_d
    printf '%s' "$_r"
}

confirm() {
    printf "%s [y/N]: " "$1" >&2
    IFS= read -r _cc || _cc=""
    case "$_cc" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

is_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || return 1
    return 0
}

rand_alnum() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | dd bs=1 count="$1" 2>/dev/null
}

rand_hex() {
    od -An -tx1 -N "$1" /dev/urandom 2>/dev/null | tr -d ' \n'
}

port_in_use() {
    _pn=$1
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v p=":${_pn}\$" '$4 ~ p {f=1} END{exit(f?0:1)}'
    elif command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${_pn}\$" '$4 ~ p {f=1} END{exit(f?0:1)}'
    else
        return 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   printf '64' ;;
        aarch64|arm64)  printf 'arm64-v8a' ;;
        armv7l|armv7)   printf 'arm32-v7a' ;;
        armv6l)         printf 'arm32-v6' ;;
        s390x)          printf 's390x' ;;
        riscv64)        printf 'riscv64' ;;
        *)              printf '' ;;
    esac
}

detect_ip() {
    for _u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip https://api.ip.sb/ip; do
        _ip=$(curl -s4 --max-time 6 "$_u" 2>/dev/null | tr -d '[:space:]')
        case "$_ip" in
            *[!0-9.]*|"") continue ;;
            *.*.*.*) printf '%s' "$_ip"; return 0 ;;
        esac
    done
    printf ''
}

# ---------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------
load_state() {
    TROJAN_ENABLED=0; T_PORT=""; T_PASS=""; T_PRIV=""; T_PUB=""; T_SID=""; T_SNI=""; T_DPORT=443
    VLESS_ENABLED=0;  V_PORT=""; V_UUID=""; V_PRIV=""; V_PUB=""; V_SID=""; V_SNI=""; V_PATH=""; V_DPORT=443
    NODE_HOST=""
    [ -f "$STATE" ] && . "$STATE"
}

save_state() {
    mkdir -p "$CONF_DIR"
    {
        printf 'TROJAN_ENABLED="%s"\n' "$TROJAN_ENABLED"
        printf 'T_PORT="%s"\n' "$T_PORT"
        printf 'T_PASS="%s"\n' "$T_PASS"
        printf 'T_PRIV="%s"\n' "$T_PRIV"
        printf 'T_PUB="%s"\n' "$T_PUB"
        printf 'T_SID="%s"\n' "$T_SID"
        printf 'T_SNI="%s"\n' "$T_SNI"
        printf 'T_DPORT="%s"\n' "$T_DPORT"
        printf 'VLESS_ENABLED="%s"\n' "$VLESS_ENABLED"
        printf 'V_PORT="%s"\n' "$V_PORT"
        printf 'V_UUID="%s"\n' "$V_UUID"
        printf 'V_PRIV="%s"\n' "$V_PRIV"
        printf 'V_PUB="%s"\n' "$V_PUB"
        printf 'V_SID="%s"\n' "$V_SID"
        printf 'V_SNI="%s"\n' "$V_SNI"
        printf 'V_DPORT="%s"\n' "$V_DPORT"
        printf 'V_PATH="%s"\n' "$V_PATH"
        printf 'NODE_HOST="%s"\n' "$NODE_HOST"
    } > "$STATE"
    chmod 600 "$STATE" 2>/dev/null
}

# ---------------------------------------------------------------------
# 依赖 / 内核 / 服务
# ---------------------------------------------------------------------
ensure_deps() {
    _need=""
    command -v curl  >/dev/null 2>&1 || _need="${_need} curl"
    command -v unzip >/dev/null 2>&1 || _need="${_need} unzip"
    [ -f /etc/ssl/certs/ca-certificates.crt ] || _need="${_need} ca-certificates"
    if [ -n "$_need" ]; then
        info "安装依赖:${_need}"
        apk add --no-cache $_need >/dev/null 2>&1 || die "apk 安装依赖失败，请检查网络与 /etc/apk/repositories"
    fi
}

install_xray() {
    ensure_deps
    _arch=$(detect_arch)
    [ -n "$_arch" ] || die "不支持的架构: $(uname -m)"
    _asset="Xray-linux-${_arch}.zip"
    _tmp=$(mktemp -d) || die "无法创建临时目录"
    _got=0
    for _base in $MIRRORS; do
        info "下载 Xray 内核: ${_asset}"
        if curl -fL --retry 2 --connect-timeout 10 --max-time 600 \
                -o "$_tmp/xray.zip" "$_base/$_asset" 2>/dev/null; then
            _got=1; break
        fi
        warn "该源不可用，换下一个..."
    done
    [ "$_got" = "1" ] || { rm -rf "$_tmp"; die "内核下载失败（GitHub 与镜像均不可用）"; }

    if ! unzip -o "$_tmp/xray.zip" -d "$_tmp" >/dev/null 2>&1; then
        busybox unzip -o "$_tmp/xray.zip" -d "$_tmp" >/dev/null 2>&1 || { rm -rf "$_tmp"; die "解压失败"; }
    fi
    [ -f "$_tmp/xray" ] || { rm -rf "$_tmp"; die "压缩包内未找到 xray 可执行文件"; }

    if [ -x "$XRAY_BIN" ]; then
        _old=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')
    else
        _old="未安装"
    fi

    mkdir -p "$(dirname "$XRAY_BIN")" "$ASSET_DIR"
    cp -f "$_tmp/xray" "$XRAY_BIN.new" || { rm -rf "$_tmp"; die "写入二进制失败"; }
    chmod 755 "$XRAY_BIN.new"
    mv -f "$XRAY_BIN.new" "$XRAY_BIN"
    for _f in geoip.dat geosite.dat; do
        [ -f "$_tmp/$_f" ] && cp -f "$_tmp/$_f" "$ASSET_DIR/$_f"
    done
    rm -rf "$_tmp"

    _new=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')
    ok "Xray 内核就绪: ${_old} -> ${_new}"
    if [ -f "$CONF" ] && rc-service xray status >/dev/null 2>&1; then
        restart_xray
    fi
}

write_init() {
    cat > "$INIT" <<'INITEOF'
#!/sbin/openrc-run

name="xray"
description="Xray Proxy Service"

export XRAY_LOCATION_ASSET="/usr/local/share/xray"

command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="true"
pidfile="/run/xray.pid"
command_user="root:root"

depend() {
    need net
    after firewall
    use dns logger
}
INITEOF
    chmod 755 "$INIT"
    rc-update add xray default >/dev/null 2>&1 || true
}

restart_xray() {
    if rc-service xray status >/dev/null 2>&1; then
        rc-service xray restart >/dev/null 2>&1
    else
        rc-service xray start >/dev/null 2>&1
    fi
    sleep 1
    if rc-service xray status >/dev/null 2>&1; then
        ok "Xray 服务运行中"
    else
        err "Xray 启动失败，最近日志："
        tail -n 20 "$LOG_DIR/error.log" 2>/dev/null
        return 1
    fi
}

# ---------------------------------------------------------------------
# 密钥 / 配置生成
# ---------------------------------------------------------------------
gen_keypair() {   # 结果写入 KP_PRIV / KP_PUB
    _out=$("$XRAY_BIN" x25519 2>/dev/null)
    KP_PRIV=$(printf '%s\n' "$_out" | awk 'NR==1{print $NF}')
    KP_PUB=$(printf '%s\n' "$_out" | awk 'NR==2{print $NF}')
    if [ -z "$KP_PUB" ] && [ -n "$KP_PRIV" ]; then
        KP_PUB=$("$XRAY_BIN" x25519 -i "$KP_PRIV" 2>/dev/null | awk 'NR==1{print $NF}')
    fi
    case "$KP_PRIV" in ''|*[!A-Za-z0-9_=-]*) return 1 ;; esac
    case "$KP_PUB"  in ''|*[!A-Za-z0-9_=-]*) return 1 ;; esac
    return 0
}

trojan_inbound() {
    cat <<EOF
    {
      "tag": "trojan-reality",
      "listen": "0.0.0.0",
      "port": ${T_PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [
          { "password": "${T_PASS}", "email": "trojan@xray" }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${T_SNI}:${T_DPORT}",
          "xver": 0,
          "serverNames": [ "${T_SNI}" ],
          "privateKey": "${T_PRIV}",
          "shortIds": [ "${T_SID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
EOF
}

vless_inbound() {
    cat <<EOF
    {
      "tag": "vless-xhttp-reality",
      "listen": "0.0.0.0",
      "port": ${V_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${V_UUID}", "email": "vless@xray" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${V_SNI}:${V_DPORT}",
          "xver": 0,
          "serverNames": [ "${V_SNI}" ],
          "privateKey": "${V_PRIV}",
          "shortIds": [ "${V_SID}" ]
        },
        "xhttpSettings": {
          "path": "${V_PATH}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
EOF
}

build_config() {
    printf '{\n'
    printf '  "log": {\n'
    printf '    "loglevel": "warning",\n'
    printf '    "access": "none",\n'
    printf '    "error": "%s/error.log"\n' "$LOG_DIR"
    printf '  },\n'
    printf '  "inbounds": [\n'
    _first=1
    if [ "${TROJAN_ENABLED:-0}" = "1" ]; then
        trojan_inbound
        _first=0
    fi
    if [ "${VLESS_ENABLED:-0}" = "1" ]; then
        [ "$_first" = "0" ] && printf ',\n'
        vless_inbound
        _first=0
    fi
    printf '\n  ],\n'
    printf '  "outbounds": [\n'
    printf '    { "tag": "direct", "protocol": "freedom" }\n'
    printf '  ]\n'
    printf '}\n'
}

apply_config() {
    mkdir -p "$CONF_DIR" "$LOG_DIR"
    build_config > "$CONF.tmp"
    if ! "$XRAY_BIN" run -test -c "$CONF.tmp" >/dev/null 2>&1; then
        err "配置校验失败："
        "$XRAY_BIN" run -test -c "$CONF.tmp" 2>&1 | tail -n 10
        rm -f "$CONF.tmp"
        return 1
    fi
    mv -f "$CONF.tmp" "$CONF"
    chmod 600 "$CONF" 2>/dev/null
    ok "配置已写入 ${CONF}"
    write_init
    restart_xray
}

# ---------------------------------------------------------------------
# 节点链接与客户端配置
# ---------------------------------------------------------------------
show_links() {
    [ -n "${NODE_HOST:-}" ] || NODE_HOST=$(detect_ip)
    [ -n "${NODE_HOST:-}" ] || NODE_HOST="<你的服务器IP>"
    line
    ok "节点信息（地址: ${NODE_HOST}）"
    if [ "${TROJAN_ENABLED:-0}" = "1" ]; then
        printf '\n[Trojan-TCP-REALITY]  端口 %s\n' "$T_PORT"
        printf 'trojan://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Trojan-Reality\n' \
            "$T_PASS" "$NODE_HOST" "$T_PORT" "$T_SNI" "$T_PUB" "$T_SID"
    fi
    if [ "${VLESS_ENABLED:-0}" = "1" ]; then
        printf '\n[VLESS-XHTTP-REALITY]  端口 %s  path /%s\n' "$V_PORT" "${V_PATH#/}"
        printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F%s&mode=auto#VLESS-XHTTP-Reality\n' \
            "$V_UUID" "$NODE_HOST" "$V_PORT" "$V_SNI" "$V_PUB" "$V_SID" "${V_PATH#/}"
    fi
    _ports=""
    [ "${TROJAN_ENABLED:-0}" = "1" ] && _ports="${_ports} ${T_PORT}/tcp"
    [ "${VLESS_ENABLED:-0}" = "1" ] && _ports="${_ports} ${V_PORT}/tcp"
    [ -n "${_ports}" ] && info "请确认防火墙 / 云安全组已放行:${_ports}"
    line
}

show_client_json() {
    [ -n "${NODE_HOST:-}" ] || NODE_HOST=$(detect_ip)
    [ -n "${NODE_HOST:-}" ] || NODE_HOST="<你的服务器IP>"
    if [ "${TROJAN_ENABLED:-0}" = "1" ]; then
        line; info "Trojan 客户端出站配置"
        cat <<EOF
{
  "protocol": "trojan",
  "settings": {
    "servers": [
      { "address": "${NODE_HOST}", "port": ${T_PORT}, "password": "${T_PASS}" }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "${T_SNI}",
      "fingerprint": "chrome",
      "publicKey": "${T_PUB}",
      "shortId": "${T_SID}",
      "spiderX": "/"
    }
  }
}
EOF
    fi
    if [ "${VLESS_ENABLED:-0}" = "1" ]; then
        line; info "VLESS-XHTTP 客户端出站配置"
        cat <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "${NODE_HOST}",
        "port": ${V_PORT},
        "users": [ { "id": "${V_UUID}", "encryption": "none" } ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "${V_SNI}",
      "fingerprint": "chrome",
      "publicKey": "${V_PUB}",
      "shortId": "${V_SID}",
      "spiderX": "/"
    },
    "xhttpSettings": {
      "path": "${V_PATH}",
      "mode": "auto"
    }
  }
}
EOF
    fi
}

# ---------------------------------------------------------------------
# 安装流程
# ---------------------------------------------------------------------
install_trojan() {
    load_state
    line; info "配置 Trojan + TCP + REALITY"

    _sni=$(prompt "伪装域名 SNI（可写 域名 或 域名:端口，需支持 TLS1.3 + H2）" "${T_SNI:-${DEFAULT_SNI_T}}:${T_DPORT:-443}")
    case "$_sni" in
        *:*)
            T_SNI=${_sni%%:*}
            T_DPORT=${_sni##*:}
            is_port "$T_DPORT" || { warn "SNI 端口无效，改用 443"; T_DPORT=443; }
            ;;
        *)  T_SNI=$_sni; T_DPORT=${T_DPORT:-443} ;;
    esac
    [ -n "$T_SNI" ] || { warn "SNI 不能为空，改用 ${DEFAULT_SNI_T}"; T_SNI=$DEFAULT_SNI_T; }

    _def_port=${T_PORT:-${AUTO_T_PORT}}
    if [ "${VLESS_ENABLED:-0}" = "1" ] && [ "$_def_port" = "${V_PORT}" ]; then _def_port=53999; fi
    while :; do
        T_PORT=$(prompt "监听端口" "$_def_port")
        is_port "$T_PORT" || { warn "端口无效，请重新输入"; continue; }
        if [ "${VLESS_ENABLED:-0}" = "1" ] && [ "$T_PORT" = "${V_PORT}" ]; then
            warn "端口 $T_PORT 已被 VLESS 入站占用，请换一个"; _def_port=53999; continue
        fi
        break
    done
    if port_in_use "$T_PORT"; then
        warn "端口 ${T_PORT} 已被其它程序监听"
        confirm "仍要继续吗?" || return 1
    fi

    if [ -n "${T_PASS:-}" ]; then
        _np=$(prompt "Trojan 密码（留空保持当前）" "")
        [ -n "$_np" ] && T_PASS=$_np
    fi
    [ -n "${T_PASS:-}" ] || T_PASS=$(rand_alnum 24)

    if [ -n "${T_PRIV:-}" ] && confirm "复用已有 REALITY 密钥对?"; then
        :
    else
        gen_keypair || die "生成 X25519 密钥失败"
        T_PRIV=$KP_PRIV; T_PUB=$KP_PUB
    fi

    [ -n "${T_SID:-}" ] || T_SID=$(rand_hex 4)
    TROJAN_ENABLED=1
    save_state
    apply_config || return 1
    show_links
}

install_vless() {
    load_state
    line; info "配置 VLESS + XHTTP + REALITY"

    _sni=$(prompt "伪装域名 SNI（可写 域名 或 域名:端口，需支持 TLS1.3 + H2）" "${V_SNI:-${DEFAULT_SNI_V}}:${V_DPORT:-443}")
    case "$_sni" in
        *:*)
            V_SNI=${_sni%%:*}
            V_DPORT=${_sni##*:}
            is_port "$V_DPORT" || { warn "SNI 端口无效，改用 443"; V_DPORT=443; }
            ;;
        *)  V_SNI=$_sni; V_DPORT=${V_DPORT:-443} ;;
    esac
    [ -n "$V_SNI" ] || { warn "SNI 不能为空，改用 ${DEFAULT_SNI_V}"; V_SNI=$DEFAULT_SNI_V; }

    _def_port=${V_PORT:-${AUTO_V_PORT}}
    if [ "${TROJAN_ENABLED:-0}" = "1" ] && [ "$_def_port" = "${T_PORT}" ]; then _def_port=53666; fi
    while :; do
        V_PORT=$(prompt "监听端口" "$_def_port")
        is_port "$V_PORT" || { warn "端口无效，请重新输入"; continue; }
        if [ "${TROJAN_ENABLED:-0}" = "1" ] && [ "$V_PORT" = "${T_PORT}" ]; then
            warn "端口 $V_PORT 已被 Trojan 入站占用，请换一个"; _def_port=53666; continue
        fi
        break
    done
    if port_in_use "$V_PORT"; then
        warn "端口 ${V_PORT} 已被其它程序监听"
        confirm "仍要继续吗?" || return 1
    fi

    if [ -n "${V_UUID:-}" ]; then
        _nu=$(prompt "VLESS UUID（留空保持当前）" "")
        [ -n "$_nu" ] && V_UUID=$_nu
    fi
    if [ -z "${V_UUID:-}" ]; then
        V_UUID=$("$XRAY_BIN" uuid 2>/dev/null)
        [ -n "$V_UUID" ] || V_UUID=$(rand_hex 16)
    fi

    if [ -n "${V_PRIV:-}" ] && confirm "复用已有 REALITY 密钥对?"; then
        :
    else
        gen_keypair || die "生成 X25519 密钥失败"
        V_PRIV=$KP_PRIV; V_PUB=$KP_PUB
    fi

    [ -n "${V_SID:-}" ] || V_SID=$(rand_hex 4)
    if [ -z "${V_PATH:-}" ]; then V_PATH="/$(rand_alnum 10)"; fi
    case "$V_PATH" in /*) : ;; *) V_PATH="/$V_PATH" ;; esac

    VLESS_ENABLED=1
    save_state
    apply_config || return 1
    show_links
}

set_host() {
    load_state
    NODE_HOST=$(prompt "节点地址或域名（留空自动检测公网 IP）" "${NODE_HOST:-}")
    save_state
    [ -n "$NODE_HOST" ] || NODE_HOST=$(detect_ip)
    ok "节点地址: ${NODE_HOST:-未检测到}"
}

enable_bbr() {
    modprobe tcp_bbr 2>/dev/null
    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        warn "当前内核不支持 BBR"
        return 1
    fi
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1
    grep -q '^tcp_bbr' /etc/modules 2>/dev/null || printf 'tcp_bbr\n' >> /etc/modules
    ok "BBR 已开启: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

uninstall_all() {
    confirm "确认卸载 Xray 内核与 OpenRC 服务（配置保留）?" || return 0
    rc-service xray stop >/dev/null 2>&1
    rc-update del xray default >/dev/null 2>&1
    rm -f "$INIT" "$XRAY_BIN"
    if confirm "同时删除配置与日志目录?"; then
        rm -rf "$CONF_DIR" "$LOG_DIR"
    fi
    ok "卸载完成"
}

# ---------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------
status_view() {
    line
    printf 'Xray 版本 : %s\n' "$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
    if rc-service xray status >/dev/null 2>&1; then
        printf '服务状态 : %s运行中%s\n' "$C_G" "$C_0"
    else
        printf '服务状态 : %s未运行%s\n' "$C_R" "$C_0"
    fi
    _auto=$(rc-update show default 2>/dev/null | awk '$1=="xray"{print "已启用"}')
    printf '开机自启 : %s\n' "${_auto:-未启用}"
    if [ "${TROJAN_ENABLED:-0}" = "1" ]; then
        printf 'Trojan   : 端口 %s  SNI %s:%s\n' "$T_PORT" "$T_SNI" "${T_DPORT:-443}"
    else
        printf 'Trojan   : 未配置\n'
    fi
    if [ "${VLESS_ENABLED:-0}" = "1" ]; then
        printf 'VLESS    : 端口 %s  SNI %s:%s  path %s\n' "$V_PORT" "$V_SNI" "${V_DPORT:-443}" "$V_PATH"
    else
        printf 'VLESS    : 未配置\n'
    fi
    line
}

menu() {
    while :; do
        printf '\n'
        printf '%s\n' "============ Xray 一键脚本 (Alpine) ============"
        printf ' 1. 安装 / 更新 Xray 内核\n'
        printf ' 2. 创建 Trojan-TCP-REALITY\n'
        printf ' 3. 创建 VLESS-XHTTP-REALITY\n'
        printf ' 4. 查看节点链接\n'
        printf ' 5. 查看客户端 JSON 配置\n'
        printf ' 6. 查看状态 / 重启服务\n'
        printf ' 7. 查看配置文件\n'
        printf ' 8. 开启 BBR\n'
        printf ' 9. 卸载\n'
        printf '10. 设置节点显示地址 / 域名\n'
        printf ' 0. 退出\n'
        printf '%s\n' "================================================"
        _c=$(prompt "请选择" "0")
        case "$_c" in
            1) install_xray ;;
            2) if [ -x "$XRAY_BIN" ]; then install_trojan; else warn "请先安装内核"; fi ;;
            3) if [ -x "$XRAY_BIN" ]; then install_vless; else warn "请先安装内核"; fi ;;
            4) load_state; show_links ;;
            5) load_state; show_client_json ;;
            6) load_state; status_view; if confirm "重启 Xray 服务?"; then restart_xray; fi ;;
            7) if [ -f "$CONF" ]; then cat "$CONF"; else warn "配置文件不存在"; fi ;;
            8) enable_bbr ;;
            9) uninstall_all ;;
            10) set_host ;;
            0) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

do_auto() {
    info "全自动模式：安装内核 + Trojan(${AUTO_T_PORT}) + VLESS-XHTTP(${AUTO_V_PORT})"
    install_xray
    load_state
    T_SNI="$DEFAULT_SNI_T"; T_PORT="$AUTO_T_PORT"; T_DPORT=443; T_PASS=$(rand_alnum 24)
    gen_keypair || die "生成密钥失败"
    T_PRIV=$KP_PRIV; T_PUB=$KP_PUB
    T_SID=$(rand_hex 4); TROJAN_ENABLED=1
    save_state
    V_SNI="$DEFAULT_SNI_V"; V_PORT="$AUTO_V_PORT"; V_DPORT=443
    V_UUID=$("$XRAY_BIN" uuid 2>/dev/null)
    [ -n "$V_UUID" ] || V_UUID=$(rand_hex 16)
    gen_keypair || die "生成密钥失败"
    V_PRIV=$KP_PRIV; V_PUB=$KP_PUB
    V_SID=$(rand_hex 4); V_PATH="/$(rand_alnum 10)"; VLESS_ENABLED=1
    save_state
    apply_config || die "部署失败"
    show_links
    show_client_json
}

main() {
    [ "$(id -u)" = "0" ] || die "请使用 root 运行本脚本"
    command -v rc-service >/dev/null 2>&1 || \
        warn "未检测到 OpenRC（rc-service），本脚本面向 OpenRC 版 Alpine；服务将无法自动注册"
    mkdir -p "$CONF_DIR" "$LOG_DIR"
    load_state
    case "${1:-}" in
        auto) do_auto ;;
        *)    menu ;;
    esac
}

main "$@"
