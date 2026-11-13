#!/bin/sh
# =====================================================================
#  xray-alpine-oneclick.sh   v2.0
#  Alpine Linux (OpenRC + BusyBox ash) Xray 一键部署脚本（多节点版）
#
#  三种入站类型，每种都能建任意多个，可同时运行、可单独管理：
#    1) Trojan + TCP   + REALITY
#    2) VLESS  + XHTTP + REALITY
#    3) VLESS  + TCP   + REALITY + xtls-rprx-vision（真 Vision）
#
#  节点清单保存在 /usr/local/etc/xray/nodes.conf（一行一个节点，| 分隔）：
#    id|类型|tag|端口|凭据|SNI|dest端口|私钥|公钥|shortId|path|备注|启用
#  可增、可删、可改端口/SNI/凭据/备注，可临时停用（停用只是不写进配置，
#  节点记录和密钥都保留，随时再启用）。
#
#  默认值（新建节点时的默认输入，都可改）：
#    Trojan 端口 53999 / SNI www.betely.com:443
#    XHTTP  端口 53666 / SNI www.amd.com:443
#    Vision 端口 53777 / SNI www.betely.com:443
#    VLESS UUID  5e226409-60a2-4479-a314-67494fd71fae
#  SNI 可填 "域名" 或 "域名:端口"（端口即 REALITY 的 dest 端口）
#
#  用法：
#    chmod +x xray-alpine-oneclick.sh
#    ./xray-alpine-oneclick.sh          # 菜单模式
#    ./xray-alpine-oneclick.sh auto     # 全自动：装内核 + 三个默认节点
#    ./xray-alpine-oneclick.sh list     # 只打印节点清单与链接
#
#  从 v1.x 升级：第一次运行会把 oneclick.conf 里的三条固定节点自动迁移成
#  等价的三条节点记录（原文件备份为 oneclick.conf.bak-v1），链接不变。
#
#  兼容性（v1.4 起）：
#    - 临时配置文件用 .json 后缀。Xray 25+ 按扩展名判断配置格式，
#      叫 config.json.tmp 会报 "Failed to get format of ..."
#    - Xray 26 起字段改名：streamSettings.network -> method、tcp -> raw、
#      settings.clients -> users。脚本会先按已存写法校验，失败自动换另一种，
#      并用 xray run -dump 确认用户字段真的被内核解析。
#    - Trojan 入站不写 flow：xtls-rprx-vision 是 VLESS 专有，
#      面板里的 "Trojan-TCP-Vision" 只是叫法，REALITY 场景下无需 flow。
#    - v1.6 新增真实 Vision 节点（VLESS+TCP+REALITY+flow），并内置 TCP 调优。
#    - v1.7 默认 SNI 改为 www.betely.com（Trojan / Vision）与 www.amd.com（XHTTP）。
#    - v1.8 生成的 mihomo 配置加了 support-x25519mlkem768: true。原因：
#      Xray 服务端 >= 26.7.11 会直接检查 ClientHello 里有没有 X25519MLKEM768，
#      没有就判为无效连接，mihomo 侧全部报 "REALITY authentication failed"。
#    - v2.0 多节点：任意数量入站 + 节点清单 + 增删改查 + 默认 UUID。
# =====================================================================

XRAY_BIN="/usr/local/bin/xray"
ASSET_DIR="/usr/local/share/xray"
CONF_DIR="/usr/local/etc/xray"
CONF="${CONF_DIR}/config.json"
LOG_DIR="/var/log/xray"
STATE="${CONF_DIR}/oneclick.conf"
NODES="${CONF_DIR}/nodes.conf"
INIT="/etc/init.d/xray"

# 默认端口（新建节点时的默认输入）
AUTO_T_PORT=53999
AUTO_V_PORT=53666
AUTO_VIS_PORT=53777
DEFAULT_SNI_T="www.betely.com"
DEFAULT_SNI_V="www.amd.com"
DEFAULT_SNI_VIS="www.betely.com"
# 默认 VLESS UUID
DEFAULT_UUID="5e226409-60a2-4479-a314-67494fd71fae"
TUNE_CONF="/etc/sysctl.d/99-xray.conf"

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
sanitize() {
    printf '%s' "$1" | tr '|' '/' | tr -d '\r\n'
}

# ---------------------------------------------------------------------
# 全局设置（节点显示地址、配置写法）
# ---------------------------------------------------------------------
load_state() {
    NODE_HOST=""
    SCHEMA="new"
    [ -f "$STATE" ] && . "$STATE" 2>/dev/null
    case "$SCHEMA" in new|legacy) : ;; *) SCHEMA="new" ;; esac
}

save_state() {
    mkdir -p "$CONF_DIR"
    {
        printf 'NODE_HOST="%s"\n' "$NODE_HOST"
        printf 'SCHEMA="%s"\n' "$SCHEMA"
    } > "$STATE"
    chmod 600 "$STATE" 2>/dev/null
}

# ---------------------------------------------------------------------
# 节点清单层
#   1=id 2=类型 3=tag 4=端口 5=凭据 6=SNI 7=dest端口
#   8=私钥 9=公钥 10=shortId 11=path 12=备注 13=启用(1/0)
# ---------------------------------------------------------------------
ensure_nodes() {
    mkdir -p "$CONF_DIR"
    [ -f "$NODES" ] || : > "$NODES"
    chmod 600 "$NODES" 2>/dev/null
}

node_field() {
    [ -f "$NODES" ] || return 0
    awk -F'|' -v id="$1" -v i="$2" '$1==id { print $i; exit }' "$NODES" 2>/dev/null
}

node_exists() {
    [ -n "$(node_field "$1" 1)" ]
}

node_count() {
    if [ -f "$NODES" ]; then
        awk 'NF>0{n++} END{print n+0}' "$NODES"
    else
        printf '0'
    fi
}

node_enabled_count() {
    if [ -f "$NODES" ]; then
        awk -F'|' 'NF>0 && $13=="1"{n++} END{print n+0}' "$NODES"
    else
        printf '0'
    fi
}

node_next_id() {
    if [ -f "$NODES" ]; then
        _nn=$(awk -F'|' 'NF>0 && $1+0>m {m=$1+0} END{print m+0}' "$NODES")
    else
        _nn=0
    fi
    printf '%s' "$((_nn + 1))"
}

node_by_index() {
    [ -f "$NODES" ] || return 0
    awk -F'|' -v n="$1" 'NF>0 { c++; if (c==n) { print $1; exit } }' "$NODES" 2>/dev/null
}

node_port_used() {
    [ -f "$NODES" ] || { printf '0'; return 0; }
    if awk -F'|' -v p="$1" 'NF>0 && $4==p { f=1 } END{ exit(f?0:1) }' "$NODES"; then
        printf '1'
    else
        printf '0'
    fi
}

next_free_port() {
    _nfp=$1
    while [ "$(node_port_used "$_nfp")" = "1" ]; do
        _nfp=$((_nfp + 1))
        [ "$_nfp" -gt 65535 ] && { printf '%s' "$1"; return 0; }
    done
    printf '%s' "$_nfp"
}

node_add() {
    ensure_nodes
    _na_id=$(node_next_id)
    _na_tag="$(node_tag_prefix "$N_TYPE")-${_na_id}"
    _na_rm=$(sanitize "${N_REMARK:-}")
    [ -n "$_na_rm" ] || _na_rm="$(type_label "$N_TYPE")-$N_PORT"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|1\n' \
        "$_na_id" "$N_TYPE" "$_na_tag" "$N_PORT" "$N_CRED" "$N_SNI" "${N_DPORT:-443}" \
        "$N_PRIV" "$N_PUB" "$N_SID" "${N_PATH:--}" "$_na_rm" >> "$NODES"
    chmod 600 "$NODES" 2>/dev/null
    printf '%s' "$_na_id"
}

node_update() {
    [ -f "$NODES" ] || return 1
    _nu_t=$(mktemp 2>/dev/null) || _nu_t="${NODES}.tmp"
    if V="$3" awk -F'|' -v OFS='|' -v id="$1" -v i="$2" '$1==id { $i = ENVIRON["V"] } { print }' "$NODES" > "$_nu_t"; then
        mv -f "$_nu_t" "$NODES"
    else
        rm -f "$_nu_t"
        return 1
    fi
    chmod 600 "$NODES" 2>/dev/null
    return 0
}

node_remove() {
    [ -f "$NODES" ] || return 0
    _nr_t=$(mktemp 2>/dev/null) || _nr_t="${NODES}.tmp"
    awk -F'|' -v OFS='|' -v id="$1" '$1!=id { print }' "$NODES" > "$_nr_t" && mv -f "$_nr_t" "$NODES"
    chmod 600 "$NODES" 2>/dev/null
    return 0
}

node_toggle() {
    if [ "$(node_field "$1" 13)" = "1" ]; then
        node_update "$1" 13 0
    else
        node_update "$1" 13 1
    fi
}

type_label() {
    case "$1" in
        trojan) printf 'Trojan-TCP-REALITY' ;;
        xhttp)  printf 'VLESS-XHTTP-REALITY' ;;
        vision) printf 'VLESS-TCP-Vision-REALITY' ;;
        *)      printf '%s' "$1" ;;
    esac
}

node_tag_prefix() {
    case "$1" in
        trojan) printf 'trojan' ;;
        xhttp)  printf 'xhttp' ;;
        vision) printf 'vision' ;;
        *)      printf '%s' "$1" ;;
    esac
}

type_base_port() {
    case "$1" in
        trojan) printf '%s' "$AUTO_T_PORT" ;;
        xhttp)  printf '%s' "$AUTO_V_PORT" ;;
        vision) printf '%s' "$AUTO_VIS_PORT" ;;
        *)      printf '53999' ;;
    esac
}

type_sni() {
    case "$1" in
        trojan) printf '%s' "$DEFAULT_SNI_T" ;;
        xhttp)  printf '%s' "$DEFAULT_SNI_V" ;;
        vision) printf '%s' "$DEFAULT_SNI_VIS" ;;
        *)      printf 'www.betely.com' ;;
    esac
}

# 把 v1.x 的固定三条节点迁移成节点清单
migrate_legacy() {
    [ -f "$NODES" ] && [ "$(node_count)" -gt 0 ] && return 0
    [ -f "$STATE" ] || return 0
    ensure_nodes
    (
        TROJAN_ENABLED=0; VLESS_ENABLED=0; VISION_ENABLED=0
        T_PORT=""; T_PASS=""; T_PRIV=""; T_PUB=""; T_SID=""; T_SNI=""; T_DPORT=""
        V_PORT=""; V_UUID=""; V_PRIV=""; V_PUB=""; V_SID=""; V_SNI=""; V_DPORT=""; V_PATH=""
        VIS_PORT=""; VIS_UUID=""; VIS_PRIV=""; VIS_PUB=""; VIS_SID=""; VIS_SNI=""; VIS_DPORT=""
        . "$STATE" 2>/dev/null
        if [ "$TROJAN_ENABLED" = "1" ] && [ -n "$T_PORT" ]; then
            N_TYPE=trojan; N_PORT=$T_PORT; N_CRED=$T_PASS
            N_SNI=${T_SNI:-$DEFAULT_SNI_T}; N_DPORT=${T_DPORT:-443}
            N_PRIV=$T_PRIV; N_PUB=$T_PUB; N_SID=$T_SID
            N_PATH=-; N_REMARK="Trojan-Reality"
            node_add >/dev/null
        fi
        if [ "$VLESS_ENABLED" = "1" ] && [ -n "$V_PORT" ]; then
            N_TYPE=xhttp; N_PORT=$V_PORT; N_CRED=$V_UUID
            N_SNI=${V_SNI:-$DEFAULT_SNI_V}; N_DPORT=${V_DPORT:-443}
            N_PRIV=$V_PRIV; N_PUB=$V_PUB; N_SID=$V_SID
            N_PATH=${V_PATH:--}; N_REMARK="VLESS-XHTTP"
            node_add >/dev/null
        fi
        if [ "$VISION_ENABLED" = "1" ] && [ -n "$VIS_PORT" ]; then
            N_TYPE=vision; N_PORT=$VIS_PORT; N_CRED=$VIS_UUID
            N_SNI=${VIS_SNI:-$DEFAULT_SNI_VIS}; N_DPORT=${VIS_DPORT:-443}
            N_PRIV=$VIS_PRIV; N_PUB=$VIS_PUB; N_SID=$VIS_SID
            N_PATH=-; N_REMARK="VLESS-Vision"
            node_add >/dev/null
        fi
    )
    _mg_n=$(node_count)
    if [ "$_mg_n" -gt 0 ]; then
        cp -f "$STATE" "${STATE}.bak-v1" 2>/dev/null
        save_state
        ok "已把旧版固定节点迁移为节点清单（${_mg_n} 条），原状态备份 oneclick.conf.bak-v1"
    fi
}
# ---------------------------------------------------------------------
# 配置写法兼容（Xray 26.x 起改过字段名）
#   streamSettings.network -> method，传输名 tcp -> raw
#   settings.clients      -> users
# SCHEMA=new 用新写法，SCHEMA=legacy 用旧写法；apply_config 会自动探测切换。
# ---------------------------------------------------------------------
SCHEMA="new"
_net_key() { if [ "$SCHEMA" = "legacy" ]; then printf 'network'; else printf 'method'; fi; }
_net_val() {
    if [ "$SCHEMA" = "legacy" ]; then printf '%s' "$1"
    else case "$1" in tcp) printf 'raw' ;; *) printf '%s' "$1" ;; esac; fi
}
_users_key() { if [ "$SCHEMA" = "legacy" ]; then printf 'clients'; else printf 'users'; fi; }
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
    # 顺带下发 TCP 调优（幂等）：高延迟链路上不做这个，"停顿后速度上不来"
    enable_tuning
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

# ---------------------------------------------------------------------
# 配置生成
# ---------------------------------------------------------------------
inbound_json() {   # 1=类型 2=tag 3=端口 4=凭据 5=SNI 6=dest端口 7=私钥 8=公钥 9=shortId 10=path
    _ij_t=$1; _ij_tag=$2; _ij_port=$3; _ij_cred=$4
    _ij_sni=$5; _ij_dport=$6; _ij_priv=$7; _ij_sid=$9; _ij_path=${10}
    case "$_ij_t" in
    trojan)
        cat <<EOF
    {
      "tag": "${_ij_tag}",
      "listen": "0.0.0.0",
      "port": ${_ij_port},
      "protocol": "trojan",
      "settings": {
        "$(_users_key)": [
          { "password": "${_ij_cred}", "email": "${_ij_tag}@xray" }
        ]
      },
      "streamSettings": {
        "$(_net_key)": "$(_net_val tcp)",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${_ij_sni}:${_ij_dport}",
          "xver": 0,
          "serverNames": [ "${_ij_sni}" ],
          "privateKey": "${_ij_priv}",
          "shortIds": [ "${_ij_sid}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
EOF
        ;;
    xhttp)
        cat <<EOF
    {
      "tag": "${_ij_tag}",
      "listen": "0.0.0.0",
      "port": ${_ij_port},
      "protocol": "vless",
      "settings": {
        "$(_users_key)": [
          { "id": "${_ij_cred}", "email": "${_ij_tag}@xray" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "$(_net_key)": "$(_net_val xhttp)",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${_ij_sni}:${_ij_dport}",
          "xver": 0,
          "serverNames": [ "${_ij_sni}" ],
          "privateKey": "${_ij_priv}",
          "shortIds": [ "${_ij_sid}" ]
        },
        "xhttpSettings": {
          "path": "${_ij_path}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
EOF
        ;;
    vision)
        cat <<EOF
    {
      "tag": "${_ij_tag}",
      "listen": "0.0.0.0",
      "port": ${_ij_port},
      "protocol": "vless",
      "settings": {
        "$(_users_key)": [
          { "id": "${_ij_cred}", "flow": "xtls-rprx-vision", "email": "${_ij_tag}@xray" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "$(_net_key)": "$(_net_val tcp)",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${_ij_sni}:${_ij_dport}",
          "xver": 0,
          "serverNames": [ "${_ij_sni}" ],
          "privateKey": "${_ij_priv}",
          "shortIds": [ "${_ij_sid}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
EOF
        ;;
    esac
}

build_config() {
    printf '{\n'
    printf '  "log": {\n'
    printf '    "loglevel": "warning",\n'
    printf '    "access": "none",\n'
    printf '    "error": "%s/error.log"\n' "$LOG_DIR"
    printf '  },\n'
    printf '  "inbounds": [\n'
    _bc_first=1
    if [ -f "$NODES" ]; then
        while IFS='|' read -r _bc_id _bc_t _bc_tag _bc_port _bc_cred _bc_sni _bc_dport \
                              _bc_priv _bc_pub _bc_sid _bc_path _bc_rm _bc_en; do
            [ -n "$_bc_id" ] || continue
            [ "$_bc_en" = "1" ] || continue
            [ "$_bc_first" = "0" ] && printf ',\n'
            inbound_json "$_bc_t" "$_bc_tag" "$_bc_port" "$_bc_cred" "$_bc_sni" \
                         "$_bc_dport" "$_bc_priv" "$_bc_pub" "$_bc_sid" "$_bc_path"
            _bc_first=0
        done < "$NODES"
    fi
    printf '\n  ],\n'
    printf '  "outbounds": [\n'
    printf '    { "tag": "direct", "protocol": "freedom" }\n'
    printf '  ]\n'
    printf '}\n'
}

# 内核是否真的解析出了用户（字段改名会被静默丢弃，-test 查不出来）
_probe_user() {
    [ -x "$XRAY_BIN" ] || return 0
    [ -f "$NODES" ] || return 0
    _pd=$("$XRAY_BIN" run -dump -c "$1" 2>/dev/null)
    [ -n "$_pd" ] || return 0
    _pmiss=0
    while IFS='|' read -r _pi _pt _ptg _pport _pcred _psni _pdp _ppv _ppb _psid _ppath _prm _pen; do
        [ -n "$_pi" ] || continue
        [ "$_pen" = "1" ] || continue
        [ -n "$_pcred" ] || continue
        printf '%s' "$_pd" | grep -F -q -e "$_pcred" || _pmiss=1
    done < "$NODES"
    return $_pmiss
}

apply_config() {
    mkdir -p "$CONF_DIR" "$LOG_DIR"
    # 临时文件必须带 .json 后缀：Xray 25+ 按扩展名判断配置格式
    _tmp="${CONF_DIR}/config.test.json"
    _try=${SCHEMA:-new}
    SCHEMA=$_try
    build_config > "$_tmp"
    if ! _tout=$("$XRAY_BIN" run -test -c "$_tmp" 2>&1); then
        _e1=$_tout
        if [ "$_try" = "new" ]; then SCHEMA=legacy; else SCHEMA=new; fi
        build_config > "$_tmp"
        if ! _tout=$("$XRAY_BIN" run -test -c "$_tmp" 2>&1); then
            err "配置校验失败（new / legacy 两种写法都没通过）："
            printf '%s\n' "$_e1" | tail -n 10 >&2
            printf '%s\n' "$_tout" | tail -n 10 >&2
            SCHEMA=$_try
            rm -f "$_tmp"
            return 1
        fi
        ok "当前内核不认原写法，已自动改用 network/clients"
    fi
    if ! _probe_user "$_tmp"; then
        _oldschema=$SCHEMA
        if [ "$SCHEMA" = "new" ]; then SCHEMA=legacy; else SCHEMA=new; fi
        build_config > "$_tmp"
        if _probe_user "$_tmp" && "$XRAY_BIN" run -test -c "$_tmp" >/dev/null 2>&1; then
            ok "已按内核实际字段名调整写法（${SCHEMA}）"
        else
            SCHEMA=$_oldschema
            build_config > "$_tmp"
        fi
    fi
    mv -f "$_tmp" "$CONF"
    chmod 600 "$CONF" 2>/dev/null
    ok "配置已写入 ${CONF}"
    save_state
    write_init
    restart_xray
}

# ---------------------------------------------------------------------
# 链接 / 列表 / 客户端配置
# ---------------------------------------------------------------------
node_host() {
    if [ -n "$NODE_HOST" ]; then
        printf '%s' "$NODE_HOST"
    else
        _nh=$(detect_ip)
        printf '%s' "${_nh:-SERVER_IP}"
    fi
}

node_link() {   # 1=id
    _nl_id=$1
    [ -n "$(node_field "$_nl_id" 1)" ] || return 0
    _nl_t=$(node_field "$_nl_id" 2)
    _nl_tag=$(node_field "$_nl_id" 3)
    _nl_port=$(node_field "$_nl_id" 4)
    _nl_cred=$(node_field "$_nl_id" 5)
    _nl_sni=$(node_field "$_nl_id" 6)
    _nl_pub=$(node_field "$_nl_id" 9)
    _nl_sid=$(node_field "$_nl_id" 10)
    _nl_path=$(node_field "$_nl_id" 11)
    _nl_host=$(node_host)
    case "$_nl_t" in
    trojan)
        printf 'trojan://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#SG-%s\n' \
            "$_nl_cred" "$_nl_host" "$_nl_port" "$_nl_sni" "$_nl_pub" "$_nl_sid" "$_nl_tag"
        ;;
    xhttp)
        _nl_p=$(printf '%s' "$_nl_path" | sed 's#^/##')
        printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F%s&mode=auto#SG-%s\n' \
            "$_nl_cred" "$_nl_host" "$_nl_port" "$_nl_sni" "$_nl_pub" "$_nl_sid" "$_nl_p" "$_nl_tag"
        ;;
    vision)
        printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#SG-%s\n' \
            "$_nl_cred" "$_nl_host" "$_nl_port" "$_nl_sni" "$_nl_pub" "$_nl_sid" "$_nl_tag"
        ;;
    esac
}

list_nodes() {
    ensure_nodes
    migrate_legacy
    if [ "$(node_count)" -eq 0 ]; then
        warn "还没有任何节点，菜单 2 可以新建"
        return 0
    fi
    printf '\n'
    printf '%-3s %-24s %-22s %-6s %-28s %s\n' "ID" "备注" "类型" "端口" "SNI" "状态"
    line
    _ln_i=0
    while IFS='|' read -r _ln_id _ln_t _ln_tag _ln_port _ln_cred _ln_sni _ln_dp _ln_pr _ln_pb _ln_sd _ln_path _ln_rm _ln_en; do
        [ -n "$_ln_id" ] || continue
        _ln_i=$((_ln_i + 1))
        case "$_ln_en" in 1) _ln_st="运行中" ;; *) _ln_st="已停用" ;; esac
        printf '%-3s %-24s %-22s %-6s %-28s %s\n' \
            "$_ln_id" "$_ln_rm" "$(type_label "$_ln_t")" "$_ln_port" \
            "$_ln_sni:$_ln_dp" "$_ln_st"
    done < "$NODES"
    line
    printf '共 %s 个节点，其中 %s 个已启用\n' "$(node_count)" "$(node_enabled_count)"
}

show_links() {
    ensure_nodes
    migrate_legacy
    if [ "$(node_count)" -eq 0 ]; then
        warn "还没有任何节点，菜单 2 可以新建"
        return 0
    fi
    _sl_host=$(node_host)
    printf '\n'
    info "节点地址：$_sl_host（菜单 10 可改）"
    printf '\n'
    _sl_i=0
    while IFS='|' read -r _sl_id _sl_t _sl_tag _sl_port _sl_cred _sl_sni _sl_dp _sl_pr _sl_pb _sl_sd _sl_path _sl_rm _sl_en; do
        [ -n "$_sl_id" ] || continue
        _sl_i=$((_sl_i + 1))
        if [ "$_sl_en" = "1" ]; then _sl_st="" ; else _sl_st="（已停用，链接不可用）"; fi
        printf '%s  #%s %s  端口 %s  SNI %s:%s%s\n' \
            "--------" "$_sl_id" "$_sl_rm" "$_sl_port" "$_sl_sni" "$_sl_dp" "$_sl_st"
        node_link "$_sl_id"
        printf '\n'
    done < "$NODES"
    warn "非 443 端口的 REALITY 节点，请在防火墙/云安全组放行对应 TCP 端口。"
    warn "客户端指纹请用 chrome/firefox/safari/random，不要用 edge/ios。"
}

client_json() {   # 1=id
    _cj_id=$1
    [ -n "$(node_field "$_cj_id" 1)" ] || return 0
    _cj_t=$(node_field "$_cj_id" 2)
    _cj_tag=$(node_field "$_cj_id" 3)
    _cj_port=$(node_field "$_cj_id" 4)
    _cj_cred=$(node_field "$_cj_id" 5)
    _cj_sni=$(node_field "$_cj_id" 6)
    _cj_pub=$(node_field "$_cj_id" 9)
    _cj_sid=$(node_field "$_cj_id" 10)
    _cj_path=$(node_field "$_cj_id" 11)
    _cj_host=$(node_host)
    _cj_nk=$(_net_key)
    case "$_cj_t" in
    trojan)
        cat <<EOF
    {
      "tag": "SG-${_cj_tag}",
      "protocol": "trojan",
      "settings": {
        "servers": [ { "address": "${_cj_host}", "port": ${_cj_port}, "password": "${_cj_cred}" } ]
      },
      "streamSettings": {
        "${_cj_nk}": "$(_net_val tcp)",
        "security": "reality",
        "realitySettings": {
          "serverName": "${_cj_sni}",
          "fingerprint": "chrome",
          "publicKey": "${_cj_pub}",
          "shortId": "${_cj_sid}"
        }
      }
    }
EOF
        ;;
    xhttp)
        cat <<EOF
    {
      "tag": "SG-${_cj_tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "${_cj_host}", "port": ${_cj_port},
            "users": [ { "id": "${_cj_cred}", "encryption": "none" } ] }
        ]
      },
      "streamSettings": {
        "${_cj_nk}": "$(_net_val xhttp)",
        "security": "reality",
        "realitySettings": {
          "serverName": "${_cj_sni}",
          "fingerprint": "chrome",
          "publicKey": "${_cj_pub}",
          "shortId": "${_cj_sid}"
        },
        "xhttpSettings": { "path": "${_cj_path}", "mode": "auto" }
      }
    }
EOF
        ;;
    vision)
        cat <<EOF
    {
      "tag": "SG-${_cj_tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "${_cj_host}", "port": ${_cj_port},
            "users": [ { "id": "${_cj_cred}", "encryption": "none", "flow": "xtls-rprx-vision" } ] }
        ]
      },
      "streamSettings": {
        "${_cj_nk}": "$(_net_val tcp)",
        "security": "reality",
        "realitySettings": {
          "serverName": "${_cj_sni}",
          "fingerprint": "chrome",
          "publicKey": "${_cj_pub}",
          "shortId": "${_cj_sid}"
        }
      }
    }
EOF
        ;;
    esac
}

show_client_json() {
    ensure_nodes
    migrate_legacy
    if [ "$(node_count)" -eq 0 ]; then
        warn "还没有任何节点，菜单 2 可以新建"
        return 0
    fi
    _sj_n=$(node_count)
    _sj_a=$(prompt "输出哪个节点（编号，A=全部）" "A")
    if [ "$_sj_a" = "A" ] || [ "$_sj_a" = "a" ]; then
        printf '{\n  "log": { "loglevel": "warning" },\n  "inbounds": [\n'
        printf '    { "tag": "socks-in", "listen": "127.0.0.1", "port": 1080, "protocol": "socks",\n'
        printf '      "settings": { "udp": true } }\n'
        printf '  ],\n  "outbounds": [\n'
        _sj_first=1
        while IFS='|' read -r _sj_id _sj_t _sj_tag _sj_port _sj_cred _sj_sni _sj_dp _sj_pr _sj_pb _sj_sd _sj_path _sj_rm _sj_en; do
            [ -n "$_sj_id" ] || continue
            [ "$_sj_en" = "1" ] || continue
            [ "$_sj_first" = "0" ] && printf ',\n'
            client_json "$_sj_id"
            _sj_first=0
        done < "$NODES"
        printf '\n    ,{ "tag": "direct", "protocol": "freedom" }\n  ]\n}\n'
    else
        [ -n "$(node_field "$_sj_a" 1)" ] || { err "没有编号 %s 的节点" "$_sj_a"; return 1; }
        printf '{\n  "log": { "loglevel": "warning" },\n  "outbounds": [\n'
        client_json "$_sj_a"
        printf '    ,{ "tag": "direct", "protocol": "freedom" }\n  ]\n}\n'
    fi
}

show_mihomo_yaml() {
    ensure_nodes
    migrate_legacy
    if [ "$(node_enabled_count)" -eq 0 ]; then
        warn "没有已启用的节点"
        return 0
    fi
    _my_host=$(node_host)
    printf '# mihomo / Clash.Meta 片段（v2.0 生成）\n'
    printf '# 硬约束 1：client-fingerprint 只可用 chrome/firefox/safari/random；edge/ios 会被 REALITY 判为无效连接。\n'
    printf '# 硬约束 2：support-x25519mlkem768 必须保留。Xray 服务端 >= 26.7.11 会检查 ClientHello 里\n'
    printf '#           有没有 X25519MLKEM768，缺失即报 REALITY authentication failed。\n'
    printf 'proxies:\n'
    while IFS='|' read -r _my_id _my_t _my_tag _my_port _my_cred _my_sni _my_dp _my_pr _my_pb _my_sd _my_path _my_rm _my_en; do
        [ -n "$_my_id" ] || continue
        [ "$_my_en" = "1" ] || continue
        case "$_my_t" in
        trojan)
            cat <<EOF
  - name: "SG-${_my_tag}"
    type: trojan
    server: ${_my_host}
    port: ${_my_port}
    password: "${_my_cred}"
    sni: ${_my_sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: "${_my_pb}"
      short-id: "${_my_sd}"
      support-x25519mlkem768: true
    udp: true
EOF
            ;;
        xhttp)
            cat <<EOF
  - name: "SG-${_my_tag}"
    type: vless
    server: ${_my_host}
    port: ${_my_port}
    uuid: "${_my_cred}"
    network: xhttp
    tls: true
    servername: ${_my_sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: "${_my_pb}"
      short-id: "${_my_sd}"
      support-x25519mlkem768: true
    xhttp-opts:
      path: "${_my_path}"
      mode: auto
      headers:
        Host: ${_my_sni}
    udp: true
EOF
            ;;
        vision)
            cat <<EOF
  - name: "SG-${_my_tag}"
    type: vless
    server: ${_my_host}
    port: ${_my_port}
    uuid: "${_my_cred}"
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: ${_my_sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: "${_my_pb}"
      short-id: "${_my_sd}"
      support-x25519mlkem768: true
    udp: true
EOF
            ;;
        esac
    done < "$NODES"
    printf '\nproxy-groups:\n  - name: "PROXY"\n    type: select\n    proxies:\n'
    while IFS='|' read -r _m3_id _m3_t _m3_tag _m3_rest; do
        [ -n "$_m3_id" ] || continue
        _m3_en=$(printf '%s' "$_m3_rest" | awk -F'|' '{print $NF}')
        [ "$_m3_en" = "1" ] || continue
        printf '      - "SG-%s"\n' "$_m3_tag"
    done < "$NODES"
    printf '      - DIRECT\n'
    warn "把上面内容并入你的 config.yaml 后 mihomo -t 校验再加载。"
}

# ---------------------------------------------------------------------
# 新建节点
# ---------------------------------------------------------------------
new_uuid() {
    if [ -x "$XRAY_BIN" ]; then
        _nu=$("$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]')
        case "$_nu" in
            ????????-????-????-????-????????????) printf '%s' "$_nu"; return 0 ;;
        esac
    fi
    _h=$(rand_hex 16)
    printf '%s-%s-%s-%s-%s' \
        "$(printf '%s' "$_h" | cut -c1-8)" \
        "$(printf '%s' "$_h" | cut -c9-12)" \
        "$(printf '%s' "$_h" | cut -c13-16)" \
        "$(printf '%s' "$_h" | cut -c17-20)" \
        "$(printf '%s' "$_h" | cut -c21-32)"
}

cred_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

require_kernel() {
    [ -x "$XRAY_BIN" ] || die "还没安装 Xray 内核，请先在菜单 1 安装"
}

# 端口：结果写入 ASK_PORT
ask_port() {   # 1=默认值 2=忽略占用检查的节点id（可选）
    _ap_def=$1
    _ap_own=${2-}
    while : ; do
        _ap=$(prompt "端口" "$_ap_def")
        if ! is_port "$_ap"; then
            warn "端口非法：$_ap"
            continue
        fi
        if [ "${node_port_used "$_ap"}" = "1" ]; then
            if [ -n "$_ap_own" ] && [ "$(node_field "$_ap_own" 4)" = "$_ap" ]; then
                ASK_PORT=$_ap
                return 0
            fi
            warn "端口 $_ap 已被其它节点占用"
            _ap_def=$(next_free_port $((_ap + 1)))
            continue
        fi
        if port_in_use "$_ap"; then
            warn "端口 $_ap 已被本机其它程序监听"
            _ap_def=$(next_free_port $((_ap + 1)))
            continue
        fi
        ASK_PORT=$_ap
        return 0
    done
}

# SNI：结果写入 ASK_SNI / ASK_DPORT
ask_sni() {
    _as_def=$1
    while : ; do
        _as=$(prompt "SNI（域名 或 域名:端口）" "$_as_def")
        [ -n "$_as" ] || _as=$_as_def
        case "$_as" in
            *:*) _ash=$(printf '%s' "$_as" | cut -d: -f1); _asp=$(printf '%s' "$_as" | cut -d: -f2) ;;
            *)   _ash=$_as; _asp=443 ;;
        esac
        _ash=$(sanitize "$_ash")
        if [ -z "$_ash" ]; then
            warn "域名不能为空"
            continue
        fi
        case "$_ash" in
            *[!A-Za-z0-9.-]*) warn "域名含非法字符：$_ash"; continue ;;
        esac
        if ! is_port "$_asp"; then
            warn "端口非法（$_asp），回退 443"
            _asp=443
        fi
        ASK_SNI=$_ash
        ASK_DPORT=$_asp
        return 0
    done
}

# 凭据：结果写入 ASK_CRED
ask_cred() {   # 1=名称 2=默认值
    _ac_name=$1
    _ac_def=${2-}
    while : ; do
        _ac=$(prompt "$_ac_name" "$_ac_def")
        if ! cred_ok "$_ac"; then
            warn "只能包含字母、数字、下划线、连字符，且不能为空"
            continue
        fi
        ASK_CRED=$_ac
        return 0
    done
}

add_node() {   # 1=类型
    _ad_t=$1
    require_kernel
    printf '\n'
    line
    info "新建 $(type_label "$_ad_t") 节点"
    line
    _ad_pdef=$(next_free_port "$(type_base_port "$_ad_t")")
    ask_port "$_ad_pdef" || return 1
    N_PORT=$ASK_PORT
    ask_sni "$(type_sni "$_ad_t")" || return 1
    N_SNI=$ASK_SNI
    N_DPORT=$ASK_DPORT
    case "$_ad_t" in
        trojan) ask_cred "Trojan 密码" "$(new_uuid)" || return 1 ;;
        *)      ask_cred "UUID" "$DEFAULT_UUID" || return 1 ;;
    esac
    N_CRED=$ASK_CRED
    N_PATH=-
    if [ "$_ad_t" = "xhttp" ]; then
        _ad_p=$(prompt "XHTTP path" "/$(rand_alnum 10)")
        case "$_ad_p" in /*) : ;; *) _ad_p="/$_ad_p" ;; esac
        N_PATH=$(sanitize "$_ad_p")
    fi
    info "生成 REALITY 密钥对..."
    if ! gen_keypair; then
        err "x25519 生成失败，内核可能损坏（菜单 1 可重装）"
        return 1
    fi
    N_PRIV=$KP_PRIV
    N_PUB=$KP_PUB
    N_SID=$(rand_hex 4)
    N_REMARK=$(sanitize "$(prompt "备注" "$(type_label "$_ad_t")-$N_PORT")")
    [ -n "$N_REMARK" ] || N_REMARK="$(type_label "$_ad_t")-$N_PORT"
    N_TYPE=$_ad_t
    _ad_id=$(node_add)
    if [ -z "$_ad_id" ]; then
        err "写入节点清单失败"
        return 1
    fi
    ok "已新增节点 #${_ad_id}（tag $(node_field "$_ad_id" 3)）"
    if apply_config; then
        printf '\n'
        ok "该节点已上线，链接如下："
        printf '\n'
        node_link "$_ad_id"
        printf '\n'
        return 0
    fi
    node_remove "$_ad_id"
    warn "配置应用失败，已回滚该节点（#${_ad_id} 已删除）"
    return 1
}

add_node_menu() {
    while : ; do
        printf '\n'
        line
        printf '  新建节点\n'
        line
        printf '  1) Trojan + TCP + REALITY           默认端口 %s、SNI %s\n' "$AUTO_T_PORT" "$DEFAULT_SNI_T"
        printf '  2) VLESS  + XHTTP + REALITY         默认端口 %s、SNI %s\n' "$AUTO_V_PORT" "$DEFAULT_SNI_V"
        printf '  3) VLESS  + TCP + Vision + REALITY  默认端口 %s、SNI %s\n' "$AUTO_VIS_PORT" "$DEFAULT_SNI_VIS"
        printf '  ------------------------------------------------\n'
        printf '  0) 返回\n'
        line
        _am=$(prompt "选择" "0")
        case "$_am" in
            1) add_node trojan ;;
            2) add_node xhttp ;;
            3) add_node vision ;;
            0|"") return 0 ;;
            *) warn "无效选择：$_am" ;;
        esac
    done
}

# ---------------------------------------------------------------------
# 管理节点
# ---------------------------------------------------------------------
node_apply_field() {   # 1=id 2=字段号 3=新值 4=旧值 5=名称
    if ! node_update "$1" "$2" "$3"; then
        err "写入节点清单失败"
        return 1
    fi
    if apply_config; then
        ok "$5 已更新"
        return 0
    fi
    node_update "$1" "$2" "$4"
    warn "$5 更新失败，已回滚为原来的 $4"
    return 1
}

node_detail() {   # 1=id
    _nd_id=$1
    printf '\n'
    printf '  #%s   %s\n' "$_nd_id" "$(node_field "$_nd_id" 12)"
    printf '  类型    %s\n' "$(type_label "$(node_field "$_nd_id" 2)")"
    printf '  tag     %s\n' "$(node_field "$_nd_id" 3)"
    printf '  端口    %s\n' "$(node_field "$_nd_id" 4)"
    printf '  SNI     %s:%s\n' "$(node_field "$_nd_id" 6)" "$(node_field "$_nd_id" 7)"
    printf '  凭据    %s\n' "$(node_field "$_nd_id" 5)"
    printf '  公钥    %s\n' "$(node_field "$_nd_id" 9)"
    printf '  shortId %s\n' "$(node_field "$_nd_id" 10)"
    if [ "$(node_field "$_nd_id" 2)" = "xhttp" ]; then
        printf '  path    %s\n' "$(node_field "$_nd_id" 11)"
    fi
    if [ "$(node_field "$_nd_id" 13)" = "1" ]; then
        printf '  状态    已启用\n'
    else
        printf '  状态    已停用\n'
    fi
}

manage_node() {
    ensure_nodes
    migrate_legacy
    if [ "$(node_count)" -eq 0 ]; then
        warn "还没有任何节点，菜单 2 可以新建"
        return 0
    fi
    list_nodes
    printf '\n'
    _mn_id=$(prompt "要管理的节点编号（0=返回）" "0")
    case "$_mn_id" in 0|"") return 0 ;; esac
    if [ -z "$(node_field "$_mn_id" 1)" ]; then
        err "没有编号 %s 的节点" "$_mn_id"
        return 1
    fi
    while : ; do
        _mn_t=$(node_field "$_mn_id" 2)
        _mn_rm=$(node_field "$_mn_id" 12)
        _mn_port=$(node_field "$_mn_id" 4)
        _mn_sni=$(node_field "$_mn_id" 6)
        _mn_dp=$(node_field "$_mn_id" 7)
        _mn_cred=$(node_field "$_mn_id" 5)
        _mn_path=$(node_field "$_mn_id" 11)
        _mn_en=$(node_field "$_mn_id" 13)
        if [ "$_mn_en" = "1" ]; then _mn_st="已启用"; else _mn_st="已停用"; fi
        printf '\n'
        line
        printf '  管理 #%s %s  |  %s  |  端口 %s  |  SNI %s:%s  |  %s\n' \
            "$_mn_id" "$_mn_rm" "$(type_label "$_mn_t")" "$_mn_port" "$_mn_sni" "$_mn_dp" "$_mn_st"
        line
        printf '  1) 看详情      2) 改备注      3) 改端口     4) 改 SNI\n'
        printf '  5) 改凭据      6) 重生成密钥  7) 改 path    8) 启停\n'
        printf '  9) 打印链接    10) 删除       0) 返回\n'
        line
        _mn_c=$(prompt "选择" "0")
        case "$_mn_c" in
        1) node_detail "$_mn_id" ;;
        2)
            _v=$(sanitize "$(prompt "新备注" "$_mn_rm")")
            [ -n "$_v" ] || { warn "备注不能为空"; continue; }
            node_apply_field "$_mn_id" 12 "$_v" "$_mn_rm" "备注"
            ;;
        3)
            ask_port "$_mn_port" "$_mn_id"
            [ "$ASK_PORT" = "$_mn_port" ] && { warn "端口没变"; continue; }
            node_apply_field "$_mn_id" 4 "$ASK_PORT" "$_mn_port" "端口"
            ;;
        4)
            ask_sni "$_mn_sni:$_mn_dp"
            if ! node_update "$_mn_id" 6 "$ASK_SNI"; then
                err "写入失败"
                continue
            fi
            if ! node_update "$_mn_id" 7 "$ASK_DPORT"; then
                node_update "$_mn_id" 6 "$_mn_sni"
                err "写入失败"
                continue
            fi
            if apply_config; then
                ok "SNI 已更新为 ${ASK_SNI}:${ASK_DPORT}"
            else
                node_update "$_mn_id" 6 "$_mn_sni"
                node_update "$_mn_id" 7 "$_mn_dp"
                warn "更新失败，SNI 已回滚为 ${_mn_sni}:${_mn_dp}"
            fi
            ;;
        5)
            if [ "$_mn_t" = "trojan" ]; then
                ask_cred "新 Trojan 密码" "$_mn_cred"
            else
                ask_cred "新 UUID" "$_mn_cred"
            fi
            node_apply_field "$_mn_id" 5 "$ASK_CRED" "$_mn_cred" "凭据"
            ;;
        6)
            info "重新生成密钥对..."
            if ! gen_keypair; then
                err "x25519 生成失败"
                continue
            fi
            _old_priv=$(node_field "$_mn_id" 8)
            _old_pub=$(node_field "$_mn_id" 9)
            node_update "$_mn_id" 8 "$KP_PRIV"
            node_update "$_mn_id" 9 "$KP_PUB"
            if apply_config; then
                ok "密钥已更新，客户端需换用新的 publicKey："
                printf '\n'
                node_link "$_mn_id"
                printf '\n'
            else
                node_update "$_mn_id" 8 "$_old_priv"
                node_update "$_mn_id" 9 "$_old_pub"
                warn "更新失败，密钥已回滚"
            fi
            ;;
        7)
            if [ "$_mn_t" != "xhttp" ]; then
                warn "只有 XHTTP 节点有 path"
                continue
            fi
            _v=$(prompt "新 path" "$_mn_path")
            case "$_v" in /*) : ;; *) _v="/$_v" ;; esac
            _v=$(sanitize "$_v")
            node_apply_field "$_mn_id" 11 "$_v" "$_mn_path" "path"
            ;;
        8)
            node_toggle "$_mn_id"
            if apply_config; then
                if [ "$(node_field "$_mn_id" 13)" = "1" ]; then
                    ok "节点 #${_mn_id} 已启用"
                else
                    ok "节点 #${_mn_id} 已停用（记录与密钥保留，可随时再启用）"
                fi
            else
                node_toggle "$_mn_id"
                warn "启停失败，状态已回滚"
            fi
            ;;
        9) node_link "$_mn_id" ;;
        10)
            if [ "$_mn_t" = "trojan" ]; then : ; fi
            if confirm "确认删除节点 #${_mn_id}（${_mn_rm}）？该节点的密钥与记录都会消失"; then
                node_remove "$_mn_id"
                if apply_config; then
                    ok "节点 #${_mn_id} 已删除"
                else
                    warn "配置应用失败，节点已从清单移除，请检查配置"
                fi
                return 0
            fi
            ;;
        0|"") return 0 ;;
        *) warn "无效选择：$_mn_c" ;;
        esac
    done
}
set_host() {
    load_state
    NODE_HOST=$(prompt "节点地址或域名（留空自动检测公网 IP）" "${NODE_HOST:-}")
    save_state
    [ -n "$NODE_HOST" ] || NODE_HOST=$(detect_ip)
    ok "节点地址: ${NODE_HOST:-未检测到}"
}
enable_tuning() {
    modprobe tcp_bbr 2>/dev/null
    _bbr=0
    if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        _bbr=1
    else
        warn "当前内核不支持 BBR，仅下发其余 TCP 调优"
    fi

    mkdir -p /etc/sysctl.d
    {
        printf '# Xray 网络调优（xray-alpine-oneclick.sh 生成）\n'
        if [ "$_bbr" = "1" ]; then
            printf 'net.core.default_qdisc = fq\n'
            printf 'net.ipv4.tcp_congestion_control = bbr\n'
        fi
        cat <<'TUNEEOF'
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
net.core.somaxconn = 8192
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
TUNEEOF
    } > "$TUNE_CONF"

    sysctl -p "$TUNE_CONF" >/dev/null 2>&1
    if [ "$_bbr" = "1" ]; then
        grep -q '^tcp_bbr' /etc/modules 2>/dev/null || printf 'tcp_bbr\n' >> /etc/modules
    fi

    # 开机生效：Alpine 的 sysctl 服务会读 /etc/sysctl.d/*.conf，再用 local.d 兜底
    rc-update add sysctl boot >/dev/null 2>&1 || true
    mkdir -p /etc/local.d
    cat > /etc/local.d/99-xray-tuning.start <<'LOCALEOF'
#!/bin/sh
# Xray TCP 调优兜底（sysctl 服务未跑到时）
[ -f /etc/sysctl.d/99-xray.conf ] && sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1
exit 0
LOCALEOF
    chmod +x /etc/local.d/99-xray-tuning.start
    rc-update add local default >/dev/null 2>&1 || true

    ok "TCP 调优已写入 ${TUNE_CONF}"
    printf '    拥塞控制      : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '    空闲后慢启动  : %s  （0=关闭，关键项）\n' "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
    printf '    notsent_lowat : %s\n' "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
    printf '    收发缓冲上限  : %s / %s\n' "$(sysctl -n net.core.rmem_max 2>/dev/null)" "$(sysctl -n net.core.wmem_max 2>/dev/null)"
}

# 兼容旧调用名
enable_bbr() { enable_tuning; }
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
# 状态 / 菜单 / 全自动
# ---------------------------------------------------------------------
status_view() {
    printf '\n'
    line
    if [ -x "$XRAY_BIN" ]; then
        printf '  Xray 内核  %s\n' "$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
    else
        printf '  Xray 内核  未安装\n'
    fi
    if command -v rc-service >/dev/null 2>&1; then
        _sv=$(rc-service xray status 2>&1 | head -n 1)
        printf '  服务状态   %s\n' "$_sv"
    fi
    printf '  节点数量   %s 个（启用 %s 个）\n' "$(node_count)" "$(node_enabled_count)"
    printf '  节点地址   %s\n' "$(node_host)"
    printf '  配置写法   %s\n' "$SCHEMA"
    if [ -d "$LOG_DIR" ]; then
        printf '  错误日志   %s/error.log\n' "$LOG_DIR"
    fi
    line
    if [ -x "$XRAY_BIN" ] && [ -f "$CONF" ]; then
        if "$XRAY_BIN" run -test -c "$CONF" >/dev/null 2>&1; then
            ok "当前配置校验通过"
        else
            err "当前配置校验失败，请看菜单 8 或日志"
        fi
    fi
}

menu() {
    while : ; do
        printf '\n'
        line
        printf '   Xray 一键脚本 v2.0   Alpine / OpenRC          节点：%s 个（启用 %s）\n' \
            "$(node_count)" "$(node_enabled_count)"
        line
        printf '   1) 安装 / 更新 Xray 内核      2) 新建节点\n'
        printf '   3) 节点列表 + 全部链接        4) 管理节点（改/删/启停）\n'
        printf '   5) 客户端 JSON                6) mihomo 配置片段\n'
        printf '   7) 状态 / 重启服务            8) 查看服务端配置\n'
        printf '   9) TCP 调优（BBR + sysctl）   10) 设置节点地址 / 域名\n'
        printf '   11) 卸载 Xray                 0) 退出\n'
        line
        _mc=$(prompt "选择" "0")
        case "$_mc" in
            1) install_xray ;;
            2) add_node_menu ;;
            3) list_nodes; show_links ;;
            4) manage_node ;;
            5) show_client_json ;;
            6) show_mihomo_yaml ;;
            7) status_view; restart_xray; status_view ;;
            8) if [ -f "$CONF" ]; then printf '\n'; cat "$CONF"; printf '\n'; else warn "还没有配置，先新建节点"; fi ;;
            9) enable_tuning ;;
            10) set_host ;;
            11) uninstall_all ;;
            0|"") ok "再见"; return 0 ;;
            *) warn "无效选择：$_mc" ;;
        esac
    done
}

_auto_add() {   # 1=类型（非交互，参数用默认值）
    _aa_t=$1
    N_TYPE=$_aa_t
    N_PORT=$(next_free_port "$(type_base_port "$_aa_t")")
    N_SNI=$(type_sni "$_aa_t")
    N_DPORT=443
    case "$_aa_t" in
        trojan) N_CRED=$(new_uuid) ;;
        *)      N_CRED=$DEFAULT_UUID ;;
    esac
    if ! gen_keypair; then
        err "x25519 生成失败"
        return 1
    fi
    N_PRIV=$KP_PRIV
    N_PUB=$KP_PUB
    N_SID=$(rand_hex 4)
    N_PATH=-
    [ "$_aa_t" = "xhttp" ] && N_PATH="/$(rand_alnum 10)"
    N_REMARK="$(type_label "$_aa_t")"
    _aa_id=$(node_add)
    [ -n "$_aa_id" ] || { err "写入节点清单失败"; return 1; }
    ok "已新增 #${_aa_id} $(type_label "$_aa_t")  端口 ${N_PORT}  SNI ${N_SNI}:${N_DPORT}"
}

do_auto() {
    printf '\n'
    info "全自动模式：安装内核 + 三个默认节点"
    if [ ! -x "$XRAY_BIN" ]; then
        install_xray || die "内核安装失败"
    fi
    _au_t=$(node_count)
    if [ "$_au_t" -gt 0 ]; then
        warn "已有 %s 个节点，自动模式只会补上缺的类型" "$_au_t"
    fi
    _au_have=" "
    if [ -f "$NODES" ]; then
        _au_have=$(awk -F'|' 'NF>0{printf " %s ", $2}' "$NODES")
    fi
    for _au_k in trojan xhttp vision; do
        case "$_au_have" in
            *" $_au_k "*) ok "已有 %s 类型节点，跳过" "$_au_k" ;;
            *) _auto_add "$_au_k" ;;
        esac
    done
    if apply_config; then
        printf '\n'
        show_links
    else
        err "配置应用失败"
        return 1
    fi
}

main() {
    [ "$(id -u)" = "0" ] || die "请用 root 运行（su - 或 sudo）"
    if ! command -v rc-service >/dev/null 2>&1; then
        warn "未检测到 OpenRC，本脚本面向 Alpine Linux，其它发行版可能不可用"
    fi
    load_state
    ensure_nodes
    migrate_legacy
    case "${1:-}" in
        auto)  do_auto ;;
        list)  list_nodes; show_links ;;
        nodes) list_nodes ;;
        "")    menu ;;
        *)     printf '用法: %s [auto|list|nodes]\n' "$0" ;;
    esac
}

main "$@"
